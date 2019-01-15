defmodule Random.Supervisor do
  @behaviour :supervisor

  # See http://erlang.org/doc/man/supervisor.html
  # for more information on OTP Supervisors
  def start_link() do
    :supervisor.start_link({:local, __MODULE__}, __MODULE__, [])
  end

  @impl :supervisor
  def init([]) do
    path_opts = %{
      "Random.RandomService" => Random.Handler
    }

    child_specs = [
      %{
        id: Phalanx.Supervisor,
        start: {Phalanx.Supervisor, :start_link, [path_opts]},
        restart: :permanent,
        shutdown: 5000,
        type: :supervisor,
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
