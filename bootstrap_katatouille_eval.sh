#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"

#---- helpers
mk() { mkdir -p "$1"; }
wt() { # write file if not exists; otherwise skip (prevent accidental clobber)
  local path="$1"
  shift
  if [[ -f "$path" ]]; then
    echo "skip (exists): $path"
  else
    echo "write: $path"
    cat > "$path" <<'EOF'
'"$@"'
EOF
  fi
}

echo "==> Creating Katatouille Eval Harness skeleton at $ROOT"

#---------------------------
# Gradle root
#---------------------------
wt "$ROOT/settings.gradle.kts" 'rootProject.name = "katatouille-eval"
include("runner")
'

wt "$ROOT/build.gradle.kts" 'plugins {
    kotlin("jvm") version "2.0.0" apply false
}

allprojects {
    repositories { mavenCentral() }
}
'

wt "$ROOT/gradle.properties" 'org.gradle.parallel=true
org.gradle.configuration-cache=true
kotlin.code.style=official
'

#---------------------------
# Runner module
#---------------------------
mk "$ROOT/runner/src/main/kotlin/app"
mk "$ROOT/runner/src/main/kotlin/core"
mk "$ROOT/runner/src/main/kotlin/domain"
mk "$ROOT/runner/src/main/resources/webreport"

wt "$ROOT/runner/build.gradle.kts" 'plugins {
    application
    kotlin("jvm") version "2.0.0"
}

application {
    mainClass.set("app.MainKt")
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.17.2")
    implementation("com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.17.2")
    implementation("org.eclipse.jgit:org.eclipse.jgit:6.10.0.202406032230-r")
    implementation("org.jetbrains.kotlinx:kotlinx-cli:0.3.6")
    implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.0")
    testImplementation(kotlin("test"))
}

tasks.withType<Jar> {
    manifest { attributes["Main-Class"] = "app.MainKt" }
}
'

#---------------------------
# App entry
#---------------------------
wt "$ROOT/runner/src/main/kotlin/app/Main.kt" 'package app
fun main(args: Array<String>) = Cli().main(args)
'

wt "$ROOT/runner/src/main/kotlin/app/Cli.kt" 'package app

import core.*
import domain.*
import kotlinx.cli.*

class Cli {
    fun main(args: Array<String>) {
        val parser = ArgParser("kat-eval")
        val suite by parser.option(ArgType.String, description = "Path to suite yaml").required()
        val outDir by parser.option(ArgType.String, description = "Output dir").default("out")
        val offline by parser.option(ArgType.Boolean, description = "Offline dry-run").default(false)
        parser.parse(args)

        val cfg = Config.load("config/models.yaml")
        val suiteCfg = Suite.load(suite)
        val judge = JudgeClient(cfg.judge)
        val builderA = BuilderClient(cfg.builderPrimary)
        val builderB = BuilderClient(cfg.builderFallback)

        val run = EvalRun(suiteCfg.suite, outDir)
        val scorer = Scorer(run)
        val reporter = Reporter(run)

        for (task in suiteCfg.tasks) {
            val work = WorkDir.copyFixture(task.fixture, run.dirFor(task.id))
            val allowed = GlobMatcher(task.allow)
            val context = RepoContext.collect(work.root, allowed, maxBytes = 80_000)

            val plan = if (offline) Plan.minimal(allowed) else judge.plan(task, context)
            var patch = if (offline) Patch.empty() else builderA.diff(plan, context)
            if (patch.content.isBlank()) {
                patch = if (offline) Patch.empty() else builderB.diff(plan, context)
            }

            val applied = DiffApplier.apply(work.root, patch.content, allowed)
            val buildRes = GradleRunner.run(work.root, task.build.args)

            val metrics = scorer.score(task, plan, applied, buildRes, patch)
            Jsonl.append(run.resultsPath, metrics)
            println("[${task.id}] compile=${metrics["compile_status"]} tests=${metrics["tests_passed"]}/${metrics["tests_total"]} time=${metrics["duration_ms"]}ms")
        }

        reporter.writeHtml()
        println("Report: ${reporter.indexPath}")
    }
}
'

#---------------------------
# Core: model clients, utils
#---------------------------
wt "$ROOT/runner/src/main/kotlin/core/Models.kt" 'package core

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import okhttp3.*

data class ModelCfg(
    val name: String,
    val base_url: String,
    val api_key: String?,
    val model: String,
    val headers: Map<String, String> = emptyMap()
)
data class CfgFile(
    val judge: ModelCfg,
    val builder_primary: ModelCfg,
    val builder_fallback: ModelCfg
)
data class ModelConfig(val judge: ModelCfg, val builderPrimary: ModelCfg, val builderFallback: ModelCfg)

object Config {
    private val mapper = jacksonObjectMapper()
    fun load(path: String): ModelConfig {
        val text = java.io.File(path).readText()
        val m = mapper.readValue<CfgFile>(text)
        fun expand(s: String?): String? = s?.let { if (it.startsWith("ENV:")) System.getenv(it.removePrefix("ENV:")) else it }
        return ModelConfig(
            judge = m.judge.copy(api_key = expand(m.judge.api_key)),
            builderPrimary = m.builder_primary.copy(api_key = expand(m.builder_primary.api_key)),
            builderFallback = m.builder_fallback.copy(api_key = expand(m.builder_fallback.api_key))
        )
    }
}

class JudgeClient(private val cfg: ModelCfg) {
    private val http = OkHttpClient()
    private val mapper = jacksonObjectMapper()
    fun plan(task: domain.Task, context: domain.RepoContext): domain.Plan {
        val sys = java.io.File("config/prompts/judge_plan.txt").readText()
            .replace("{{plan_prompt}}", task.planPrompt)
        val body = mapOf(
            "model" to cfg.model,
            "messages" to listOf(
                mapOf("role" to "system", "content" to sys),
                mapOf("role" to "user", "content" to "ALLOWED:\n${task.allow.joinToString("\n")}\n")
            )
        )
        val req = Request.Builder()
            .url("${cfg.base_url}/chat/completions")
            .apply {
                cfg.api_key?.let { header("Authorization", "Bearer $it") }
                cfg.headers.forEach { (k, v) -> header(k, v) }
            }
            .post(RequestBody.create(MediaType.parse("application/json"), mapper.writeValueAsBytes(body)))
            .build()
        val respStr = http.newCall(req).execute().use { it.body()?.string() ?: error("empty judge response") }
        val content = mapper.readTree(respStr)["choices"]?.get(0)?.get("message")?.get("content")?.asText() ?: "{}"
        return domain.Plan.parse(content)
    }
}

class BuilderClient(private val cfg: ModelCfg) {
    private val http = OkHttpClient()
    private val mapper = jacksonObjectMapper()
    fun diff(plan: domain.Plan, context: domain.RepoContext): domain.Patch {
        val ctx = context.toSnippet(12)
        val sys = java.io.File("config/prompts/builder_diff.txt").readText()
            .replace("{{context_snippet}}", ctx)
        val body = mapOf(
            "model" to cfg.model,
            "messages" to listOf(
                mapOf("role" to "system", "content" to sys),
                mapOf("role" to "user", "content" to "Apply the plan minimally.")
            )
        )
        val req = Request.Builder()
            .url("${cfg.base_url}/chat/completions")
            .apply {
                cfg.api_key?.let { header("Authorization", "Bearer $it") }
                cfg.headers.forEach { (k, v) -> header(k, v) }
            }
            .post(RequestBody.create(MediaType.parse("application/json"), mapper.writeValueAsBytes(body)))
            .build()
        val respStr = http.newCall(req).execute().use { it.body()?.string() ?: "" }
        val diffText = mapper.readTree(respStr)["choices"]?.get(0)?.get("message")?.get("content")?.asText() ?: ""
        return domain.Patch(diffText)
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/DiffApplier.kt" 'package core

import domain.GlobMatcher
import org.eclipse.jgit.api.Git
import java.io.ByteArrayInputStream
import java.nio.file.Path
import java.nio.file.Files

data class ApplyResult(val code: Int, val notes: List<String>)

object DiffApplier {
    fun apply(repoRoot: Path, diff: String, allowed: GlobMatcher): ApplyResult {
        if (diff.isBlank()) return ApplyResult(0, listOf("empty_patch"))

        // quick path check
        val touched = diff.lineSequence()
            .filter { it.startsWith("+++ ") || it.startsWith("--- ") || it.startsWith("diff --git") }
            .mapNotNull { line ->
                when {
                    line.startsWith("+++ b/") -> line.removePrefix("+++ b/")
                    line.startsWith("--- a/") -> line.removePrefix("--- a/")
                    line.startsWith("diff --git") -> line.split(" ").takeIf { it.size >= 4 }?.get(2)?.removePrefix("a/")
                    else -> null
                }
            }.filter { it.isNotBlank() }.toSet()

        touched.forEach { path ->
            require(allowed.matches(path)) { "Patch touches disallowed path: $path" }
        }

        if (!Files.exists(repoRoot.resolve(".git"))) {
            Git.init().setDirectory(repoRoot.toFile()).call().use { /* noop */ }
        }
        Git.open(repoRoot.toFile()).use { git ->
            val cmd = git.apply()
            cmd.setPatch(ByteArrayInputStream(diff.toByteArray()))
            cmd.call()
        }
        return ApplyResult(0, listOf("ok"))
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/GradleRunner.kt" 'package core

import java.lang.ProcessBuilder
import java.nio.file.Path

data class BuildResult(
    val exit: Int,
    val stdout: String,
    val stderr: String,
    val duration_ms: Long,
    val tests_passed: Int,
    val tests_total: Int
)

object GradleRunner {
    fun run(repo: Path, args: List<String>): BuildResult {
        val pb = ProcessBuilder(args).directory(repo.toFile())
        pb.environment()["CI"] = "true"
        val start = System.nanoTime()
        val proc = pb.redirectErrorStream(true).start()
        val out = proc.inputStream.bufferedReader().readText()
        val exit = proc.waitFor()
        val dur = (System.nanoTime() - start) / 1_000_000
        val (pass, total) = parseTests(out)
        return BuildResult(exit, out, "", dur, pass, total)
    }

    private fun parseTests(log: String): Pair<Int, Int> {
        // matches "X tests completed, Y failed" from Gradle
        val m = Regex("""(\d+)\s+tests? completed,\s+(\d+)\s+failed""").find(log) ?: return 0 to 0
        val total = m.groupValues[1].toInt()
        val failed = m.groupValues[2].toInt()
        return (total - failed) to total
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/Reporter.kt" 'package core

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

class Reporter(private val run: EvalRun) {
    val indexPath: String get() = run.outDir.resolve("report/index.html").toString()
    fun writeHtml() {
        val dst = run.outDir.resolve("report")
        Files.createDirectories(dst)
        val web = java.nio.file.Paths.get("runner/src/main/resources/webreport")
        Files.copy(web.resolve("index.html"), dst.resolve("index.html"), StandardCopyOption.REPLACE_EXISTING)
        Files.copy(web.resolve("report.js"), dst.resolve("report.js"), StandardCopyOption.REPLACE_EXISTING)
        Files.copy(run.resultsPath, dst.resolve("results.jsonl"), StandardCopyOption.REPLACE_EXISTING)
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/Jsonl.kt" 'package core

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption

object Jsonl {
    private val mapper = jacksonObjectMapper()
    fun append(path: Path, map: Map<String, Any?>) {
        Files.createDirectories(path.parent)
        Files.write(
            path,
            (mapper.writeValueAsString(map) + "\n").toByteArray(),
            StandardOpenOption.CREATE, StandardOpenOption.APPEND
        )
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/Scorer.kt" 'package core

import domain.Plan
import domain.Task
import java.nio.file.Path

class Scorer(private val run: EvalRun) {
    fun score(task: Task, plan: Plan, applied: ApplyResult, build: BuildResult, patch: domain.Patch): Map<String, Any?> {
        val compileStatus = if (build.exit == 0) "pass" else "fail"
        val scoreBase = if (compileStatus == "pass") 0.6 else 0.0
        val testPart = if (build.tests_total > 0) (build.tests_passed.toDouble() / build.tests_total) * 0.4 else 0.0
        val score = (scoreBase + testPart).coerceIn(0.0, 1.0)

        return mapOf(
            "suite" to run.suite,
            "task_id" to task.id,
            "builder_name" to "auto",
            "compile_status" to compileStatus,
            "tests_passed" to build.tests_passed,
            "tests_total" to build.tests_total,
            "duration_ms" to build.duration_ms,
            "diff_bytes" to patch.content.toByteArray().size,
            "score" to "%.3f".format(score)
        )
    }
}
'

wt "$ROOT/runner/src/main/kotlin/core/EvalRun.kt" 'package core

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

class EvalRun(val suite: String, outDir: String) {
    val outDir: Path = Paths.get(outDir)
    val resultsPath: Path = outDir.resolve("results.jsonl")
    fun dirFor(taskId: String): Path {
        val p = outDir.resolve("work/$suite/$taskId")
        Files.createDirectories(p)
        return p
    }
}
'

#---------------------------
# Domain models/helpers
#---------------------------
wt "$ROOT/runner/src/main/kotlin/domain/Task.kt" 'package domain

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.Files

data class Task(
    val id: String,
    val fixture: String,
    val allow: List<String>,
    val plan_prompt: String,
    val build: BuildSpec
) {
    val planPrompt: String get() = plan_prompt
}

data class BuildSpec(val args: List<String>)
data class SuiteDef(val suite: String, val max_attempts_per_task: Int = 1, val tasks: List<Task>)

object Suite {
    private val mapper = jacksonObjectMapper(YAMLFactory())
    fun load(path: String): SuiteDef {
        val f = java.io.File(path)
        return mapper.readValue(f, SuiteDef::class.java)
    }
}

data class Plan(val rationale: String = "minimal", val files_to_touch: List<String> = emptyList()) {
    companion object {
        fun parse(jsonText: String): Plan {
            return try {
                val node = com.fasterxml.jackson.module.kotlin.jacksonObjectMapper().readTree(jsonText)
                val rat = node.get("rationale")?.asText() ?: "minimal"
                val files = node.get("files_to_touch")?.map { it.asText() } ?: emptyList()
                Plan(rat, files)
            } catch (e: Exception) {
                Plan()
            }
        }
        fun minimal(allowed: GlobMatcher) = Plan("minimal", emptyList())
    }
}

data class Patch(val content: String) {
    companion object {
        fun empty() = Patch("")
    }
}

data class WorkDir(val root: Path) {
    companion object {
        fun copyFixture(from: String, to: Path): WorkDir {
            val src = Paths.get(from).toAbsolutePath().normalize()
            val dst = to.toAbsolutePath().normalize()
            fun cp(r: java.nio.file.Path, d: java.nio.file.Path) {
                java.nio.file.Files.walk(r).forEach { p ->
                    val rel = r.relativize(p)
                    val target = d.resolve(rel.toString())
                    if (java.nio.file.Files.isDirectory(p)) java.nio.file.Files.createDirectories(target)
                    else java.nio.file.Files.copy(p, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                }
            }
            if (!Files.exists(dst)) Files.createDirectories(dst)
            cp(src, dst)
            return WorkDir(dst)
        }
    }
}

class GlobMatcher(private val patterns: List<String>) {
    private val matchers = patterns.map { java.nio.file.FileSystems.getDefault().getPathMatcher("glob:$it") }
    fun matches(path: String): Boolean {
        val p = java.nio.file.Paths.get(path)
        return matchers.any { it.matches(p) }
    }
}

data class RepoContext(val files: List<FileSlice>) {
    data class FileSlice(val path: String, val content: String)
    fun toSnippet(maxFiles: Int): String {
        return files.take(maxFiles).joinToString("\n---\n") { "PATH: ${it.path}\n${it.content.take(4000)}" }
    }
    companion object {
        fun collect(root: Path, allow: GlobMatcher, maxBytes: Int): RepoContext {
            val out = mutableListOf<FileSlice>()
            java.nio.file.Files.walk(root).forEach { p ->
                if (java.nio.file.Files.isRegularFile(p)) {
                    val rel = root.relativize(p).toString().replace("\\", "/")
                    if (allow.matches(rel)) {
                        val bytes = java.nio.file.Files.readAllBytes(p)
                        val str = String(bytes, Charsets.UTF_8).take(maxBytes)
                        out.add(FileSlice(rel, str))
                    }
                }
            }
            return RepoContext(out)
        }
    }
}
'

#---------------------------
# Config + prompts + suites
#---------------------------
mk "$ROOT/config/prompts"
mk "$ROOT/config/suites"

wt "$ROOT/config/models.yaml" 'judge:
  name: deepseek-r1
  base_url: http://localhost:8001/v1
  api_key: "ENV:KAT_JUDGE_KEY"
  model: deepseek-r1
  headers: {}
builder_primary:
  name: mellum-kotlin
  base_url: http://localhost:8002/v1
  api_key: "ENV:KAT_BUILDER_A_KEY"
  model: JetBrains/Mellum-4B-SFT-Kotlin
  headers: {}
builder_fallback:
  name: qwen32b
  base_url: http://localhost:8003/v1
  api_key: "ENV:KAT_BUILDER_B_KEY"
  model: Qwen2.5-Coder-32B-Instruct
  headers: {}
'

wt "$ROOT/config/prompts/judge_plan.txt" 'You are the Judge/Planner. Produce a JSON plan for minimal changes, touching only ALLOWED files.
Return JSON with keys: rationale (string), files_to_touch (array of strings).

USER_PROMPT:
{{plan_prompt}}
'

wt "$ROOT/config/prompts/builder_diff.txt" 'You are the Builder. Make minimal changes to satisfy tests.
Return a single unified diff (patch) with correct file paths from repo root.
Never modify disallowed files. No commentary, diff only.

CONTEXT:
{{context_snippet}}
'

wt "$ROOT/config/suites/kotlin-core.yaml" 'suite: "kotlin-core"
max_attempts_per_task: 2
tasks:
  - id: "greeter-add-formal"
    fixture: "fixtures/kotlin-lib-greeter"
    allow:
      - "src/main/**"
      - "src/test/**"
      - "build.gradle.kts"
    plan_prompt: >
      Add a new function `greetFormally(name: String): String` that returns "Good day, {name}.".
      Update tests to cover this and keep style consistent.
    build:
      args: ["./gradlew","clean","test","--no-daemon"]
'

#---------------------------
# Fixtures (sample project)
#---------------------------
mk "$ROOT/fixtures/kotlin-lib-greeter/src/main/kotlin/demo"
mk "$ROOT/fixtures/kotlin-lib-greeter/src/test/kotlin/demo"

wt "$ROOT/fixtures/kotlin-lib-greeter/build.gradle.kts" 'plugins { kotlin("jvm") version "2.0.0" }
repositories { mavenCentral() }
dependencies { testImplementation(kotlin("test")) }
tasks.test { useJUnitPlatform() }
'

wt "$ROOT/fixtures/kotlin-lib-greeter/src/main/kotlin/demo/Greeter.kt" 'package demo
object Greeter {
    fun greet(name: String) = "Hello, $name!"
}
'

wt "$ROOT/fixtures/kotlin-lib-greeter/src/test/kotlin/demo/GreeterTest.kt" 'package demo

import kotlin.test.Test
import kotlin.test.assertEquals

class GreeterTest {
    @Test fun basic() {
        assertEquals("Hello, Alice!", Greeter.greet("Alice"))
    }
    // The Builder must implement:
    // fun greetFormally(name: String): String = "Good day, {name}."
    // And add tests for it (or modify this test file).
}
'

#---------------------------
# Web report
#---------------------------
wt "$ROOT/runner/src/main/resources/webreport/index.html" '<!doctype html><meta charset="utf-8">
<title>Katatouille Eval Report</title>
<style>
body{font-family:system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:24px;}
table{border-collapse:collapse;width:100%;}
th,td{border:1px solid #ddd;padding:8px;}
th{background:#f6f6f6;text-align:left;}
.pass{color:green;font-weight:600}
.fail{color:#b00;font-weight:600}
#summary{margin:12px 0 20px 0;font-weight:600}
</style>
<h1>Katatouille Eval</h1>
<div id="summary"></div>
<table id="tbl">
  <thead><tr>
    <th>Task</th><th>Model</th><th>Compile</th><th>Tests</th><th>Time (s)</th><th>Diff bytes</th><th>Score</th>
  </tr></thead>
  <tbody></tbody>
</table>
<script src="report.js"></script>
'

wt "$ROOT/runner/src/main/resources/webreport/report.js" '(async function(){
  const resp = await fetch("results.jsonl");
  const text = await resp.text();
  const rows = text.trim().split("\n").filter(Boolean).map(JSON.parse);
  const tbody = document.querySelector("#tbl tbody");
  let pass=0, tot=0, tests=0, testsTot=0;
  rows.forEach(r=>{
    tot++; if (r.compile_status==="pass") pass++;
    tests += (r.tests_passed||0); testsTot += (r.tests_total||0);
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${r.task_id}</td>
      <td>${r.builder_name||"auto"}</td>
      <td class="${r.compile_status}">${r.compile_status}</td>
      <td>${r.tests_passed||0}/${r.tests_total||0}</td>
      <td>${((r.duration_ms||0)/1000).toFixed(1)}</td>
      <td>${r.diff_bytes||0}</td>
      <td>${r.score||"0.0"}</td>`;
    tbody.appendChild(tr);
  });
  document.querySelector("#summary").textContent =
    `Compile: ${pass}/${tot} | Tests: ${tests}/${testsTot}`;
})();
'

#---------------------------
# Scripts (optional extras)
#---------------------------
mk "$ROOT/scripts/docker"
mk "$ROOT/scripts/k8s"

wt "$ROOT/scripts/docker/Dockerfile.kmp-dev" 'FROM eclipse-temurin:17-jammy
RUN apt-get update && apt-get install -y curl git unzip nodejs npm && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN ./gradlew --no-daemon :runner:installDist || true
CMD ["/bin/bash"]
'

wt "$ROOT/scripts/k8s/job-eval.yaml" 'apiVersion: batch/v1
kind: Job
metadata:
  name: kat-eval-run
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: run
        image: ghcr.io/YOUR_ORG/kmp-dev:latest
        command: ["bash","-lc"]
        args:
          - |
            set -e
            ./gradlew :runner:installDist
            ./runner/build/install/runner/bin/kat-eval \
              --suite config/suites/kotlin-core.yaml \
              --output out \
              --offline true
        volumeMounts:
          - name: work
            mountPath: /work
      volumes:
        - name: work
          emptyDir: {}
'

echo "==> Done."
echo
echo "Next steps:"
echo "  1) ./gradlew :runner:installDist"
echo "  2) ./runner/build/install/runner/bin/kat-eval --suite config/suites/kotlin-core.yaml --output out --offline true"
echo "  3) open out/report/index.html"
