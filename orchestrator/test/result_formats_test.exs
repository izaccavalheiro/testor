defmodule Testor.ResultFormatsTest do
  @moduledoc "JUnit, TRX, CTRF and TAP results; LCOV, Cobertura and Istanbul coverage; exports and hotspots."
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Testor.Test.Helpers
  alias Testor.{Attestation, Badge, Gates, Query, Reports, Store}
  alias Testor.Reports.{Coverage, Export, Tests, XML}

  @commit "5b6c7d8e9f00112233445566778899aabbccddee"

  @jest_junit """
  <?xml version="1.0" encoding="UTF-8"?>
  <testsuites name="jest tests" tests="3" failures="1" errors="0" time="1.5">
    <testsuite name="math" errors="0" failures="1" skipped="1" timestamp="2026-11-26T00:00:00" time="1.2" tests="3">
      <testcase classname="math adds" name="math adds" time="0.004" file="src/math.test.js"></testcase>
      <testcase classname="math subtracts" name="math subtracts" time="0.5" file="src/math.test.js">
        <failure message="expected 1 to be 2">Error: expected 1 to be 2
      at Object.&lt;anonymous&gt; (src/math.test.js:5:13)</failure>
      </testcase>
      <testcase classname="math later" name="math later" time="0" file="src/math.test.js"><skipped/></testcase>
    </testsuite>
  </testsuites>
  """

  @pytest """
  <?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="1" failures="0" skipped="0" tests="2" time="0.1">
  <testcase classname="tests.test_api" name="test_ok" time="0.01" />
  <testcase classname="tests.test_api" name="test_boom" time="0.02"><error message="fixture failed">boom</error></testcase>
  </testsuite></testsuites>
  """

  # Surefire: one file per class, a lone testsuite, times with thousands separators.
  @surefire """
  <testsuite xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="com.example.AppTest" time="1,234.5" tests="1" errors="0" skipped="0" failures="0">
    <testcase name="works" classname="com.example.AppTest" time="1,234.5"/>
  </testsuite>
  """

  @trx """
  <?xml version="1.0" encoding="utf-8"?>
  <TestRun id="1" name="run" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
    <Results>
      <UnitTestResult testId="a" testName="Adds" outcome="Passed" duration="00:00:00.0420000" />
      <UnitTestResult testId="b" testName="Fails" outcome="Failed" duration="00:00:01.5">
        <Output><ErrorInfo><Message>Assert.Equal() Failure</Message></ErrorInfo></Output>
      </UnitTestResult>
      <UnitTestResult testId="c" testName="Later" outcome="NotExecuted" />
      <UnitTestResult testId="d" testName="Lost" outcome="Passed" duration="soon" />
    </Results>
    <TestDefinitions>
      <UnitTest id="a" name="Adds" storage="app.tests.dll"><TestMethod className="App.Tests.MathTests" name="Adds" /></UnitTest>
      <UnitTest id="b" name="Fails" storage="app.tests.dll"><TestMethod className="App.Tests.MathTests" name="Fails" /></UnitTest>
      <UnitTest id="c" name="Later" storage="app.tests.dll" />
    </TestDefinitions>
  </TestRun>
  """

  @ctrf JSON.encode!(%{
          "results" => %{
            "tool" => %{"name" => "playwright"},
            "summary" => %{"tests" => 3},
            "tests" => [
              %{
                "name" => "logs in",
                "status" => "passed",
                "duration" => 1200.4,
                "filePath" => "e2e/login.spec.ts",
                "retries" => 2,
                "flaky" => true
              },
              %{
                "name" => "logs out",
                "status" => "failed",
                "duration" => 300,
                "filePath" => "e2e/login.spec.ts",
                "message" => "timeout"
              },
              %{"name" => "maybe", "status" => "pending", "suite" => "misc"},
              "not a test"
            ]
          }
        })

  @tap """
  TAP version 13
  # Subtest: test/a.test.js
      # Subtest: adds
      ok 1 - adds
        ---
        duration_ms: 0.4
        ...
      # Subtest: subtracts
      not ok 2 - subtracts
        ---
        duration_ms: 1.2
        ...
          ok 1 - deeper, not counted
      1..2
  not ok 1 - test/a.test.js
    ---
    duration_ms: 10.5
    ...
  ok 2 - test/b.test.js # SKIP not today
  not ok 3 - crashed
  ok 4
  1..4
  """

  describe "test results" do
    test "jest-junit, pytest and Surefire's JUnit XML" do
      assert {:ok, [spec]} = Tests.junit(@jest_junit)

      assert %{
               "file" => "src/math.test.js",
               "runner" => "junit",
               "tests" => 3,
               "failed" => 1,
               "skipped" => 1,
               "durationMs" => 504,
               "status" => "failed"
             } =
               spec

      assert [_, %{"status" => "failed", "message" => "expected 1 to be 2"}, %{"status" => "skipped"}] =
               spec["cases"]

      assert {:ok,
              [%{"file" => "tests.test_api", "failed" => 1, "cases" => [_, %{"message" => "fixture failed"}]}]} =
               Tests.junit(@pytest)

      assert {:ok, [%{"file" => "com.example.AppTest", "durationMs" => 1_234_500}]} = Tests.junit(@surefire)

      # A case named by its suite only; no time.
      assert {:ok, [%{"file" => "suite", "durationMs" => 0}]} =
               Tests.junit(
                 ~s(<testsuite name="suite"><testcase name="x"/><testcase name="y" time="?"/></testsuite>)
               )

      assert {:ok, [%{"file" => "(unnamed)"}]} = Tests.junit(~s(<testsuite><testcase/></testsuite>))
      assert {:ok, []} = Tests.junit("<testsuites/>")
    end

    test "dotnet's TRX, by test class" do
      assert {:ok, [math, dll, lost]} = Tests.trx(@trx)

      assert %{
               "file" => "App.Tests.MathTests",
               "tests" => 2,
               "failed" => 1,
               "durationMs" => 1542,
               "runner" => "trx"
             } = math

      assert [_, %{"message" => "Assert.Equal() Failure"}] = math["cases"]
      assert %{"file" => "app.tests.dll", "status" => "skipped"} = dll
      assert %{"file" => "(unnamed)", "durationMs" => 0} = lost
    end

    test "CTRF from Playwright's reporter" do
      assert {:ok, [login, misc]} = Tests.ctrf(@ctrf)

      assert %{
               "file" => "e2e/login.spec.ts",
               "tests" => 2,
               "failed" => 1,
               "retries" => 2,
               "durationMs" => 1500,
               "runner" => "ctrf"
             } = login

      assert [%{"flaky" => true, "retries" => 2}, %{"message" => "timeout"}] = login["cases"]
      assert %{"file" => "misc", "status" => "skipped"} = misc
      assert Tests.ctrf(~s({"results": {}})) == {:error, "no results.tests"}
      assert Tests.ctrf("nope") == {:error, "not JSON"}
    end

    test "TAP from node:test" do
      assert {:ok, [a, b, crashed, unnamed]} = Tests.tap(@tap)
      assert %{"file" => "test/a.test.js", "tests" => 2, "failed" => 1, "runner" => "tap"} = a

      assert [%{"name" => "adds", "durationMs" => 5}, %{"name" => "subtracts", "status" => "failed"}] =
               a["cases"]

      assert %{"file" => "test/b.test.js", "status" => "skipped"} = b
      assert %{"tests" => 1, "failed" => 1} = crashed
      assert %{"file" => "(unnamed)", "status" => "passed"} = unnamed

      # A failed point whose subtests passed failed itself.
      tap = "    ok 1 - inner\nnot ok 1 - outer\n"
      assert {:ok, [%{"failed" => 1}]} = Tests.tap(tap)
    end

    test "TAP never fails on noise: every point lands in one spec" do
      :rand.seed(:exsss, {1, 2, 3})

      for _ <- 1..200 do
        lines =
          for _ <- 1..:rand.uniform(30) do
            Enum.random([
              "ok #{:rand.uniform(9)} - t#{:rand.uniform(5)}",
              "not ok #{:rand.uniform(9)} - t#{:rand.uniform(5)}",
              "    ok 1 - sub",
              "    not ok 2 - sub # TODO later",
              "  duration_ms: #{:rand.uniform(100)}",
              "# comment",
              "Bail out!",
              :crypto.strong_rand_bytes(8) |> Base.encode64(),
              ""
            ])
          end

        text = Enum.join(lines, "\n")
        assert {:ok, rows} = Tests.tap(text)
        top = Enum.count(lines, &Regex.match?(~r/^(not )?ok\b/, &1))
        assert Enum.sum(Enum.map(rows, & &1["tests"])) >= min(top, 1) or top == 0
      end
    end
  end

  describe "hostile XML" do
    test "entities, external entities, depth and size are refused" do
      laughs =
        ~s(<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;">]><testsuites>&lol2;</testsuites>)

      assert {:error, "DOCTYPE and ENTITY are not accepted"} = XML.parse(laughs)
      xxe = ~s(<?xml version="1.0"?><!doctype x [<!entity e SYSTEM "file:///etc/passwd">]><x>&e;</x>)
      assert {:error, _} = Tests.junit(xxe)

      deep = String.duplicate("<a>", 70) <> String.duplicate("</a>", 70)
      assert {:error, why} = XML.parse(deep)
      assert why =~ "deeper"

      Application.put_env(:testor, :xml_max_elements, 100)
      on_exit(fn -> Application.delete_env(:testor, :xml_max_elements) end)
      many = "<testsuites>" <> String.duplicate("<testsuite/>", 200) <> "</testsuites>"
      assert {:error, why} = XML.parse(many)
      assert why =~ "elements"

      assert {:error, "not well-formed" <> _} = XML.parse("<testsuites><testsuite></testsuites>")
      assert {:error, _} = XML.parse(<<"<testsuites name=\"", 0xFF, 0xFE, "\"/>">>)
      assert {:error, "not well-formed" <> _} = XML.parse("")
      # Long text is cut.
      {:ok, root} = XML.parse("<x>" <> String.duplicate("y", 5000) <> "</x>")
      assert String.length(XML.text(root)) == 2048
    end
  end

  describe "coverage" do
    test "LCOV, Cobertura and Istanbul's summary" do
      lcov = """
      TN:
      SF:src/a.js
      FNF:2
      FNH:1
      LF:10
      LH:9
      BRF:4
      BRH:2
      end_of_record
      SF:src/b.js
      LF:10
      LH:1
      BRF:x
      end_of_record
      """

      assert {:ok, %{"lines" => 50.0, "branches" => 50.0, "functions" => 50.0, "files" => 2}, [b, a]} =
               Coverage.lcov(lcov)

      assert %{"file" => "src/b.js", "lines" => 10.0, "branches" => nil} = b
      assert %{"file" => "src/a.js", "lines" => 90.0} = a
      assert Coverage.lcov("TN:\n") == {:error, "no SF records"}

      cobertura = """
      <?xml version="1.0" ?>
      <coverage version="7.4" line-rate="0.8512" branch-rate="0.5" timestamp="1">
        <packages><package name="app"><classes>
          <class name="a.py" filename="app/a.py" line-rate="1" branch-rate="0.5"/>
          <class name="b.py" filename="app/b.py" line-rate="0.25" branch-rate="nope"/>
          <class name="x"/>
        </classes></package></packages>
      </coverage>
      """

      assert {:ok, %{"lines" => 85.12, "branches" => 50.0, "functions" => nil, "files" => 2},
              [%{"file" => "app/b.py", "branches" => nil}, _]} =
               Coverage.cobertura(cobertura)

      assert Coverage.cobertura("<report/>") == {:error, "no coverage element"}
      assert {:error, _} = Coverage.cobertura("<coverage>")

      istanbul =
        JSON.encode!(%{
          "total" => %{
            "lines" => %{"total" => 20, "covered" => 15, "pct" => 75},
            "branches" => %{"total" => 0, "covered" => 0, "pct" => 100},
            "functions" => %{"pct" => 1}
          },
          "/src/a.ts" => %{"lines" => %{"total" => 20, "covered" => 15, "pct" => 75}}
        })

      assert {:ok, %{"lines" => 75.0, "branches" => nil, "functions" => nil, "files" => 1},
              [%{"file" => "/src/a.ts"}]} = Coverage.istanbul(istanbul)

      assert Coverage.istanbul("[]") == {:error, "no total"}
      assert Coverage.istanbul("x") == {:error, "not JSON"}
    end
  end

  describe "a run with reports" do
    defp run_with(files, extra, log \\ nil) do
      id = run_id()
      File.mkdir_p!(Reports.dir(id))
      for {name, data} <- files, do: File.write!(Path.join(Reports.dir(id), name), data)
      if log, do: log(id, log)

      record(
        Map.merge(
          %{
            "id" => id,
            "project" => "formats",
            "kind" => "test",
            "source" => %{"commit" => @commit, "dirty" => false}
          },
          extra
        )
      )

      on_exit(fn -> Store.delete(id) end)
      capture_log(fn -> finish(id, "passed") end)
      wait_until(fn -> Attestation.exists?(id) end)
      id
    end

    test "kinds are told apart" do
      id = run_id()
      File.mkdir_p!(Reports.dir(id))
      on_exit(fn -> Reports.delete(id) end)

      for {name, data} <- [
            {"a.xml", @jest_junit},
            {"b.trx", @trx},
            {"c.json", @ctrf},
            {"d.tap", @tap},
            {"e.info", "SF:x\nLF:1\nLH:1\nend_of_record\n"},
            {"f.xml", ~s(<coverage line-rate="1"/>)},
            {"g.json", ~s({"total": {"lines": {"pct": 1}}})},
            {"h.txt", "hello"}
          ],
          do: File.write!(Path.join(Reports.dir(id), name), data)

      assert Enum.map(Reports.list(id), & &1["kind"]) == ~w(junit trx ctrf tap lcov cobertura istanbul file)
    end

    test "specs from its reports, merged, the log's summary kept when it differs; coverage gated" do
      id =
        run_with(
          [
            {"jest.xml", @jest_junit},
            {"more.xml", @jest_junit},
            {"lcov.info", "SF:a\nLF:4\nLH:3\nend_of_record\n"},
            {"bad.xml", "<testsuites><x>"},
            {"cov.xml", "<coverage line-rate=\"1\"><x>"}
          ],
          %{},
          " ✓ tests/other.test.ts (1 test) 1ms\n"
        )

      run = Store.get(id)
      assert %{"specsFrom" => "reports", "summary" => %{"specs" => 1, "tests" => 6, "failed" => 1}} = run
      assert %{"logSummary" => %{"specs" => 1, "passed" => 1}} = run
      assert [%{"file" => "src/math.test.js", "status" => "failed", "durationMs" => 1008}] = run["specs"]
      assert %{"lines" => 75.0, "source" => "lcov"} = run["coverage"]

      snapshot = Testor.Views.run_snapshot(id)
      assert [%{"file" => "src/math.test.js", "tests" => 6}] = snapshot["specs"]
      assert [%{"file" => "a", "lines" => 75.0}] = snapshot["coverage"]

      gate = %{"name" => "c", "project" => "formats", "kinds" => ["test"]}
      assert %{"pass" => true} = Gates.evaluate(Map.put(gate, "minCoverage", 70), @commit) |> elem(1)

      assert %{"checks" => [%{"reason" => "its line coverage 75.0% is below 80%"}]} =
               Gates.evaluate(Map.put(gate, "minCoverage", 80), @commit) |> elem(1)

      assert Badge.svg("formats", nil, "coverage") =~ ">75.0%<"

      # Exports, which read back as the same table.
      junit = Export.junit(run, Reports.run_specs(id))

      assert {:ok, [%{"file" => "src/math.test.js", "tests" => 6, "failed" => 2, "skipped" => 2}]} =
               Tests.junit(junit)

      assert %{"results" => %{"summary" => %{"tests" => 6, "failed" => 2}, "tests" => [_ | _]}} =
               Export.ctrf(run, Reports.run_specs(id))
    end

    test "the log's specs, a gate without coverage, exports over HTTP" do
      id = run_with([], %{"kind" => "lint"}, " ✓ tests/a.test.ts (2 tests) 3ms\n\e[31m\n")
      run = Store.get(id)
      refute Map.has_key?(run, "specsFrom") or Map.has_key?(run, "logSummary")

      assert %{"checks" => [%{"reason" => "its line coverage (none) is below 1%"}]} =
               Gates.evaluate(
                 %{"name" => "c", "project" => "formats", "kinds" => ["lint"], "minCoverage" => 1},
                 @commit
               )
               |> elem(1)

      conn = Plug.Test.conn(:get, "/api/v1/runs/#{id}/report.junit.xml") |> Testor.Web.Router.call([])
      assert conn.status == 200 and conn.resp_body =~ ~s(<testcase name="tests/a.test.ts")

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="#{id}.junit.xml")
             ]

      conn = Plug.Test.conn(:get, "/api/v1/runs/#{id}/report.ctrf.json") |> Testor.Web.Router.call([])
      assert %{"results" => %{"tests" => [%{"filePath" => "tests/a.test.ts"}]}} = JSON.decode!(conn.resp_body)

      assert Plug.Test.conn(:get, "/api/v1/runs/nope/report.ctrf.json")
             |> Testor.Web.Router.call([])
             |> Map.get(:status) == 404

      bare = [%{"file" => "x\e", "status" => "skipped", "durationMs" => nil}]
      assert {:ok, [_]} = Tests.junit(Export.junit(%{}, bare))
      assert %{"results" => %{"summary" => %{"start" => 0, "stop" => 0}}} = Export.ctrf(%{}, bare)
    end

    test "a flaky spec from JUnit results, and hotspots" do
      flaky_ok = String.replace(@pytest, ~s(<error message="fixture failed">boom</error>), "")
      run_with([{"r.xml", flaky_ok}], %{"project" => "flaky-junit"})
      run_with([{"r.xml", @pytest}], %{"project" => "flaky-junit"})
      run_with([{"c.json", @ctrf}], %{"project" => "flaky-junit", "kind" => "e2e"})

      assert [%{"file" => "tests.test_api", "passed" => 1, "failed" => 1}] =
               Query.flaky("flaky-junit", "test")

      assert %{
               "runs" => 2,
               "mostFailing" => [%{"file" => "tests.test_api", "failed" => 1, "failureRate" => 0.5}],
               "slowest" => [_ | _]
             } =
               Query.hotspots("flaky-junit", "test")

      assert %{"mostRetried" => [%{"file" => "e2e/login.spec.ts", "retries" => 2}]} =
               Query.hotspots("flaky-junit")

      conn =
        Plug.Test.conn(:get, "/api/v1/projects/flaky-junit/hotspots?limit=1") |> Testor.Web.Router.call([])

      assert %{"data" => %{"runs" => 1}} = JSON.decode!(conn.resp_body)

      anyone = Testor.Auth.anonymous()

      call = fn args, principal ->
        {:ok, result} = Testor.MCP.Tools.call("find_hotspots", args, principal, "")
        if result["isError"], do: {:error, result["content"]}, else: result["structuredContent"]
      end

      assert %{"mostRetried" => [_]} = call.(%{"project" => "flaky-junit"}, anyone)
      assert %{"runs" => 1} = call.(%{"project" => "flaky-junit", "limit" => 1}, anyone)
      assert {:error, _} = call.(%{"project" => "flaky-junit", "limit" => 0}, anyone)
      assert {:error, _} = call.(%{}, anyone)
      assert %{"runs" => 0} = call.(%{"project" => "flaky-junit"}, Map.put(anyone, :projects, ["other"]))
    end
  end
end
