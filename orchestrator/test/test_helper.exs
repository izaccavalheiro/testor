# The tests run the real server: the store, the trackers, the janitor, stats, sessions, device
# stats, maintenance and Bandit, on a free port of 127.0.0.1, with folders of their own (the
# machine that runs them may have real ones, with auth.json and runs).
root = Path.join(System.tmp_dir!(), "testor-test-#{System.unique_integer([:positive])}")
# A workspaces name of its own: sessions of the real workspaces (this very test run's) must not count.
workspaces = Path.join(root, "testor-ws")
data_dir = Path.join(workspaces, ".testor")
File.mkdir_p!(data_dir)

Application.put_env(:testor, :workspaces, workspaces)
Application.put_env(:testor, :data_dir, data_dir)
Application.put_env(:testor, :ip, {127, 0, 0, 1})
Application.put_env(:testor, :port, 0)

for child <- Testor.Application.server() do
  {:ok, pid} = Supervisor.start_child(Testor.Supervisor, child)

  with {Bandit, _} <- child do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:testor, :test_port, port)
  end
end

ExUnit.after_suite(fn _ -> File.rm_rf(root) end)
ExUnit.start()
