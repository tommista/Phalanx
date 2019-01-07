defmodule Phalanx.Supervisor do
  @behaviour :supervisor

  def start_link(path_opts) do
    :supervisor.start_link({:local, __MODULE__}, __MODULE__, path_opts)
  end

  @impl :supervisor
  def init(path_opts) do
    ref = Phalanx.HTTP
    dispatch = :cowboy_router.compile([{:_, [{:_, Phalanx.Handler, {path_opts, %{}}}]}])

    protocol_options = %{
      env: %{dispatch: dispatch},
      stream_handlers: [:grpc_stream_h]
    }

    child_specs = [
      {
        {:ranch_listener_sup, ref},
        {:cowboy, :start_clear, [ref, [port: 50051], protocol_options]},
        :permanent,
        :infinity,
        :supervisor,
        [:ranch_listener_sup]
      }
    ]

    sup_flags = %{
      strategy: :one_for_one,
      intensity: 1,
      period: 5
    }

    {:ok, {sup_flags, child_specs}}
  end
end