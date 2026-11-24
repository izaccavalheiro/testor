defmodule Testor.MaintenanceTest do
  use ExUnit.Case, async: true
  alias Testor.Maintenance

  @moduletag :tmp_dir

  test "old_revisions/1 keeps the newest build of each browser" do
    names = [
      "chromium-1140",
      "chromium-1155",
      "chromium_headless_shell-1155",
      "firefox-1466",
      "firefox-1471",
      ".links",
      "ffmpeg-1010"
    ]

    assert Maintenance.old_revisions(names) == ["chromium-1140", "firefox-1466"]
  end

  test "old_revisions/1 compares revisions as numbers" do
    assert Maintenance.old_revisions(["webkit-999", "webkit-1000"]) == ["webkit-999"]
  end

  test "measure/1 adds up a tree", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "a/b"))
    File.write!(Path.join(root, "a/one"), "123")
    File.write!(Path.join(root, "a/b/two"), "12")
    assert %{bytes: 5, files: 2, newest: newest} = Maintenance.measure(root)
    assert newest > 0
  end

  test "measure/1 of a missing path is nothing", %{tmp_dir: root} do
    assert Maintenance.measure(Path.join(root, "missing")) == %{bytes: 0, files: 0, newest: 0}
  end

  # Creating symbolic links needs a privilege on Windows.
  unless match?({:win32, _}, :os.type()) do
    test "measure/1 does not follow symbolic links, even in a cycle", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "pkg"))
      File.write!(Path.join(root, "pkg/index.js"), "1234567890")
      :ok = File.ln_s(root, Path.join(root, "pkg/loop"))
      assert %{files: 2} = Maintenance.measure(root)
    end
  end
end
