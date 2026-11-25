defmodule Testor.SpecParserTest do
  use ExUnit.Case, async: true
  alias Testor.{SpecParser, Store}

  defp by_file(specs), do: Map.new(specs, &{&1["file"], &1})

  describe "parse/1" do
    test "reads Vitest file lines, with ANSI colours as Vitest prints them" do
      text = """
      \e[32m✓\e[39m tests/validators.test.ts \e[2m(\e[22m\e[2m44 tests\e[22m\e[2m)\e[22m\e[32m 12\e[2mms\e[22m\e[39m
       ❯ |web| src/b.test.ts (3 tests | 1 failed) 8ms
         × renders the form 3ms
       ↓ tests/skipped.test.ts (2 tests | 2 skipped)
      """

      specs = text |> SpecParser.parse() |> by_file()
      assert %{"tests" => 44, "status" => "passed", "durationMs" => 12} = specs["tests/validators.test.ts"]
      assert %{"tests" => 3, "failed" => 1, "status" => "failed"} = specs["src/b.test.ts"]
      assert %{"status" => "skipped"} = specs["tests/skipped.test.ts"]
      assert map_size(specs) == 3
    end

    test "reads Vitest's verbose reporter per file (Vitest 5 prints passed files no other way)" do
      output = """
       ✓ tests/screenshot.test.js > saves a screenshot for the dashboard 3ms
       ✓ tests/math.test.js > arithmetic > adds 3ms
       ✓ tests/math.test.js > arithmetic > multiplies 0ms
       ↓ tests/math.test.js > arithmetic > divides
       × tests/broken.test.js > breaks 11ms
       ✓ |web| src/ui.test.ts > renders 1.5s
       FAIL  tests/broken.test.js > breaks
       ❯ tests/broken.test.js:2:34
       Test Files  1 failed | 3 passed (4)
      """

      assert [
               %{"file" => "tests/screenshot.test.js", "tests" => 1, "status" => "passed", "durationMs" => 3},
               %{
                 "file" => "tests/math.test.js",
                 "tests" => 3,
                 "skipped" => 1,
                 "status" => "passed",
                 "durationMs" => 3
               },
               %{
                 "file" => "tests/broken.test.js",
                 "tests" => 1,
                 "failed" => 1,
                 "status" => "failed",
                 "runner" => "vitest"
               },
               %{"file" => "src/ui.test.ts", "tests" => 1, "durationMs" => 1500}
             ] = SpecParser.parse(output)
    end

    test "a Vitest file's own line has its totals: its tests' lines are not added to them" do
      # Vitest 5's default reporter: the failed file's line, then its tests without the file.
      file_first =
        " ❯ tests/b.test.ts (3 tests | 1 failed) 8ms\n × tests/b.test.ts > breaks 2ms\n   × breaks 2ms"

      assert [%{"file" => "tests/b.test.ts", "tests" => 3, "failed" => 1}] = SpecParser.parse(file_first)

      # The tests first, then the file's line: the totals win.
      tests_first =
        " ✓ tests/c.test.ts > one 1ms\n ✓ tests/c.test.ts > two 1ms\n ✓ tests/c.test.ts (5 tests) 9ms"

      assert [%{"file" => "tests/c.test.ts", "tests" => 5, "durationMs" => 9}] = SpecParser.parse(tests_first)
    end

    test "reads Vitest project labels, coloured or not" do
      # As Vitest prints them in a workspace with projects (Windows line endings included).
      text =
        " \e[32m✓\e[39m \e[30m\e[42m worker-unit \e[49m\e[39m src/__tests__/capacity.test.ts " <>
          "\e[2m(\e[22m\e[2m11 tests\e[22m\e[2m)\e[22m\e[32m 73\e[2mms\e[22m\e[39m\r\n" <>
          " \e[31m❯\e[39m \e[30m\e[45m web-unit \e[49m\e[39m src/__tests__/AuthAndContact.test.tsx " <>
          "\e[2m(\e[22m\e[2m5 tests\e[22m\e[2m | \e[22m\e[31m5 failed\e[39m\e[2m)\e[22m\e[33m 3632\e[2mms\e[22m\e[39m\r\n" <>
          " ✓ |worker-integration| src/__tests__/schemas.integration.test.ts (47 tests) 49ms\n"

      specs = text |> SpecParser.parse() |> by_file()

      assert %{"tests" => 11, "status" => "passed", "durationMs" => 73} =
               specs["src/__tests__/capacity.test.ts"]

      assert %{"tests" => 5, "failed" => 5, "status" => "failed"} =
               specs["src/__tests__/AuthAndContact.test.tsx"]

      assert %{"tests" => 47, "status" => "passed"} = specs["src/__tests__/schemas.integration.test.ts"]
      assert map_size(specs) == 3
    end

    test "aggregates Playwright list-reporter lines per spec file (ok/x on Windows)" do
      text = """
      Running 3 tests using 1 worker
        ok 1 [chromium] › e2e/smoke.spec.ts:4:3 › loads (1.2s)
        x  2 [chromium] › e2e/auth.spec.ts:10:5 › signs in (3.4s)
        -  3 [chromium] › e2e/auth.spec.ts:20:5 › skipped one
        1) [chromium] › e2e/auth.spec.ts:10:5 › signs in
      """

      specs = text |> SpecParser.parse() |> by_file()
      assert %{"tests" => 1, "status" => "passed", "durationMs" => 1200} = specs["e2e/smoke.spec.ts"]
      assert %{"tests" => 2, "failed" => 1, "skipped" => 1, "status" => "failed"} = specs["e2e/auth.spec.ts"]
    end

    test "reads pytest, go test and cargo test summaries" do
      text = """
      bindings/python/tests/test_api.py ..F.s   [ 40%]
      ok  \texample.com/project\t0.12s
      FAIL\texample.com/project/http\t0.30s
           Running tests/conformance.rs (target\\debug\\deps\\conformance-1234.exe)
      test result: FAILED. 10 passed; 2 failed; 1 ignored; 0 measured; 0 filtered out
      """

      specs = text |> SpecParser.parse() |> by_file()
      assert %{"tests" => 5, "failed" => 1, "skipped" => 1} = specs["bindings/python/tests/test_api.py"]
      assert %{"status" => "passed", "durationMs" => 120} = specs["example.com/project"]
      assert %{"status" => "failed"} = specs["example.com/project/http"]
      assert %{"tests" => 13, "failed" => 2, "runner" => "cargo"} = specs["tests/conformance.rs"]
    end

    test "feeding lines in pieces gives the same specs as parsing at once" do
      lines = [" ✓ tests/a.test.ts (1 test) 1ms", " ✓ tests/b.test.ts (2 tests) 2ms"]
      fed = SpecParser.new() |> SpecParser.feed(Enum.take(lines, 1)) |> SpecParser.feed(Enum.drop(lines, 1))
      assert SpecParser.specs(fed) == SpecParser.parse(Enum.join(lines, "\n"))
    end

    test "ignores ordinary output" do
      assert SpecParser.parse("npm warn something\n> vitest run\n Test Files  9 passed (9)") == []
    end
  end

  test "summary/1 counts specs by status" do
    specs = SpecParser.parse(" ✓ a.test.ts (1 test)\n ❯ b.test.ts (2 tests | 1 failed)")

    assert SpecParser.summary(specs) == %{
             "specs" => 2,
             "passed" => 1,
             "failed" => 1,
             "skipped" => 0,
             "tests" => 3
           }
  end

  test "spec_of/2 matches Playwright result folders to their spec" do
    specs = [%{"file" => "e2e/auth.spec.ts"}, %{"file" => "e2e/auth-admin.spec.ts"}]

    assert SpecParser.spec_of("test-results/auth-admin-lists-users-chromium/a.png", specs) ==
             "e2e/auth-admin.spec.ts"

    assert SpecParser.spec_of("test-results/auth-signs-in-chromium/a.png", specs) == "e2e/auth.spec.ts"
    assert SpecParser.spec_of("screenshots/other.png", specs) == nil
  end

  test "parse_time/1 reads PowerShell's 7-digit fractions" do
    assert {:ok, time} = Store.parse_time("2026-11-24T06:59:50.1234567Z")
    assert time.microsecond == {123_456, 6}
  end
end
