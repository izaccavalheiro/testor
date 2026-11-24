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
