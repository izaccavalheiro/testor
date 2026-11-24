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

  test "remove_tree/1 deletes a tree", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "snap/a/b"))
    File.write!(Path.join(root, "snap/a/b/f"), "x")
    assert Maintenance.remove_tree(Path.join(root, "snap")) == []
    refute File.exists?(Path.join(root, "snap"))
    assert Maintenance.remove_tree(Path.join(root, "snap")) == []
  end

  # Junctions need no privilege; npm workspaces create them.
  if match?({:win32, _}, :os.type()) do
    defp win(path), do: String.replace(path, "/", "\\")

    test "remove_tree/1 removes live and dangling junctions but not their targets", %{tmp_dir: root} do
      outside = Path.join(root, "outside")
      gone = Path.join(root, "gone")
      snap = Path.join(root, "snap")
      File.mkdir_p!(outside)
      File.mkdir_p!(gone)
      File.mkdir_p!(Path.join(snap, "node_modules"))
      File.write!(Path.join(outside, "keep"), "x")

      for {link, target} <- [{"linked", outside}, {"dangling", gone}] do
        path = Path.join([snap, "node_modules", link])
        # cmd splits arguments at commas too: the tmp_dir (named after this test) has none.
        {_, 0} = System.cmd("cmd", ["/c", "mklink", "/J", win(path), win(target)])
      end

      File.rmdir!(gone)
      assert Maintenance.remove_tree(snap) == []
      refute File.exists?(snap)
      assert File.read!(Path.join(outside, "keep")) == "x"
    end
  end

  # Creating symbolic links needs a privilege on Windows.
  unless match?({:win32, _}, :os.type()) do
    test "measure/1 does not follow symbolic links, even in a cycle", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "pkg"))
      File.write!(Path.join(root, "pkg/index.js"), "1234567890")
      loop = Path.join(root, "pkg/loop")
      :ok = File.ln_s(root, loop)
      # ExUnit keeps tmp_dir; a cycle left there trips tools that walk the repository.
      on_exit(fn -> File.rm(loop) end)
      assert %{files: 2} = Maintenance.measure(root)
    end

    test "remove_tree/1 removes a symbolic link, not what it points to", %{tmp_dir: root} do
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "x")
      File.mkdir_p!(Path.join(root, "snap"))
      :ok = File.ln_s(outside, Path.join(root, "snap/link"))
      assert Maintenance.remove_tree(Path.join(root, "snap")) == []
      assert File.read!(Path.join(outside, "keep")) == "x"
    end
  end
end
