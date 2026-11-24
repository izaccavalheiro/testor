defmodule Testor.FilesTest do
  use ExUnit.Case, async: true
  alias Testor.Files

  @moduletag :tmp_dir

  describe "parse_range/2" do
    test "without a header or for an empty file, the whole file" do
      assert Files.parse_range(nil, 100) == :all
      assert Files.parse_range("bytes=0-10", 0) == :all
    end

    test "a closed, an open and a suffix range" do
      assert Files.parse_range("bytes=0-9", 100) == {0, 10}
      assert Files.parse_range("bytes=90-", 100) == {90, 10}
      assert Files.parse_range("bytes=-30", 100) == {70, 30}
    end

    test "an end past the file is cut to it, a suffix longer than the file is the file" do
      assert Files.parse_range("bytes=50-500", 100) == {50, 50}
      assert Files.parse_range("bytes=-500", 100) == {0, 100}
    end

    test "a start past the end cannot be satisfied" do
      assert Files.parse_range("bytes=100-", 100) == :unsatisfiable
    end

    test "anything else gets the whole file" do
      for header <- ["bytes=0-1,5-6", "items=0-1", "bytes=a-b", "bytes=9-3", "bytes=-0", "bytes=-"] do
        assert Files.parse_range(header, 100) == :all, header
      end
    end
  end

  test "served_type/1 serves what browsers show and downloads the rest" do
    assert Files.served_type("coverage/index.html") == "text/html; charset=utf-8"
    assert Files.served_type("NOTES.MD") == "text/plain; charset=utf-8"
    assert Files.served_type("a/video.webm") == "video/webm"
    assert Files.served_type("trace.zip") == nil
    assert Files.served_type("binary") == nil
  end

  test "artifact_kind/1" do
    assert Files.artifact_kind("v.mp4") == "video"
    assert Files.artifact_kind("badge.svg") == "image"
    assert Files.artifact_kind("r.html") == "html"
    assert Files.artifact_kind("junit.xml") == "text"
    assert Files.artifact_kind("summary.json") == "text"
    assert Files.artifact_kind("trace.zip") == "file"
  end

  test "list_artifacts/2 folds a folder with an index.html into one report", %{tmp_dir: root} do
    write = fn rel, data ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    end

    write.("coverage/index.html", "<html>")
    write.("coverage/src/a.ts.html", "12345")
    write.("notes one.md", "# hi")
    write.("test-results/login/video.webm", "vid")

    assert [
             %{
               "path" => "coverage",
               "kind" => "report",
               "files" => 2,
               "bytes" => 11,
               "url" => "/artifacts/r1/coverage/index.html"
             },
             %{"path" => "notes one.md", "kind" => "text", "url" => "/artifacts/r1/notes%20one.md"},
             %{"path" => "test-results/login/video.webm", "kind" => "video", "bytes" => 3}
           ] = Files.list_artifacts(root, "/artifacts/r1")
  end

  test "list_artifacts/2 of a missing folder is empty", %{tmp_dir: root} do
    assert Files.list_artifacts(Path.join(root, "nope"), "/artifacts/x") == []
  end
end
