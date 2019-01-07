defmodule Phalanx.Handler do
  @behaviour :cowboy_handler

  @moduledoc false

  # A cowboy handler accepting all requests and calls corresponding functions
  # defined by users.

  alias GRPC.Transport.HTTP2
  alias GRPC.RPCError
  require Logger

  @default_trailers HTTP2.server_trailers()
  @type state :: %{pid: pid, server_opts: map, message_buffer: String.t, path: String.t}

  @spec init(map, {GRPC.Server.servers_map(), map}) :: {:grpc_loop, map, map}
  def init(req, {servers, _opts}) do
    path = :cowboy_req.path(req)
    ["", package_name | _] = String.split(path, "/")
    server_module = Map.get(servers, package_name)

    server_opts =
      if(!is_nil(server_module) && Code.ensure_loaded?(server_module) && function_exported?(server_module, :meta, 0)) do
        opts = apply(server_module, :meta, [])
        Map.put(opts, :module, server_module)
      else
        # TODO handle this case
        nil
      end

    state = %{server_opts: server_opts, message_buffer: <<>>, path: path, pid: nil}

    if(!is_nil(server_opts)) do
      state =
        if(!is_nil(server_module) && Code.ensure_loaded?(server_module) && function_exported?(server_module, :initialize, 1)) do
          case apply(server_module, :initialize, [path]) do
            {:ok, pid} when is_pid(pid) ->
              Process.flag(:trap_exit, true)
              true = Process.link(pid)
              Map.put(state, :pid, pid)

            {:error, error = %GRPC.RPCError{}} ->
              send(self(), {:send_error, error})
              state
          end
        else
          state
        end

      # TODO handle timeouts

      req = :cowboy_req.set_resp_headers(HTTP2.server_headers(), req)
      {:grpc_loop, req, state}
    else
      send(self(), {:send_error, RPCError.new(:unimplemented)})
      {:ok, req, state}
    end
  end

  ## API's

  def send_reply(pid, response, fin \\ :nofin)
  def send_reply(pid, response, fin) when fin in [:fin, :nofin] do
    send(pid, {:send_reply, response, fin})
  end

  def send_error(pid, error = %GRPC.RPCError{}) do
    send(pid, {:send_error, error})
  end

  ## Info Handlers

  def info({:request_body, {:ok, data, opts}}, req, state = %{pid: pid, server_opts: server_opts}) do
    case handle_message(data, state) do
      {:ok, nil, new_state} ->
        {:ok, req, new_state}

      {:ok, message, new_state} ->
        send(self(), {:req_message, message, :fin})
        {:ok, req, new_state}
    end
  end

  def info({:request_body, {:more, data, opts}}, req, state = %{message_buffer: buffer, server_opts: server_opts}) do
    case handle_message(data, state) do
      {:ok, nil, new_state} ->
        {:ok, req, new_state}

      {:ok, message, new_state} ->
        send(self(), {:req_message, message, :nofin})
        {:ok, req, new_state}
    end
  end

  def info({:req_message, message, req_fin}, req, state = %{pid: pid, server_opts: server_opts, path: path}) do
    %{request_module: req_mod, service: service_mod, module: server_mod, response_module: resp_mod} = server_opts

    if(!is_nil(service_mod) && Code.ensure_loaded?(service_mod) && function_exported?(server_mod, :request_message, 4)) do
      case apply(server_mod, :request_message, [path, message, req_fin, %{pid: pid}]) do
        {:ok, :noreply} ->
          {:ok, req, state}

        {:ok, response = %{__struct__: ^resp_mod}} ->
          send(self(), {:send_reply, response, :fin})
          {:ok, req, state}

        {:error, error = %GRPC.RPCError{}} ->
          send(self(), {:send_error, error})
          {:ok, req, state}
      end
    else
      {:ok, req, state}
    end
  end

  def info({:send_error, error = %GRPC.RPCError{}}, req, state) do
    trailers = HTTP2.server_trailers(error.status, error.message)
    req = send_trailers_over_the_wire(req, trailers, state)
    {:stop, req, state}
  end

  def info({:send_reply, response = %{__struct__: resp_mod}, fin}, req, state = %{server_opts: server_opts}) do
    %{response_stream?: is_streaming} = server_opts

    {:ok, data} = marshal_response(server_opts, response)
    fin = if(is_streaming, do: fin, else: :fin)

    # TODO handle trailers

    req = send_response_over_the_wire(req, data)

    if(fin === :fin) do
      send_trailers_over_the_wire(req, @default_trailers, state)
    end

    {:ok, req, state}
  end

  def info({:send_reply, response}, req, state) do
    send(self(), {:send_error, GRPC.RPCError.new(:internal)})
    {:ok, req, state}
  end

  def info({:EXIT, pid, :killed}, req, state = %{pid: pid}) do
    exit_handler(pid, :killed)
    {:stop, req, %{state | pid: nil}}
  end

  def info({:EXIT, pid, :normal}, req, state = %{pid: pid}) do
    exit_handler(pid, :normal)
    {:stop, req, %{state | pid: nil}}
  end

  # expected error raised from user to return error immediately
  def info({:EXIT, pid, {%RPCError{} = error, _stacktrace}}, req, state = %{pid: pid}) do
    trailers = HTTP2.server_trailers(error.status, error.message)
    exit_handler(pid, :rpc_error)
    req = send_error_trailers(req, trailers)
    {:stop, req, state}
  end

  # unknown error raised from rpc
  def info({:EXIT, pid, {:handle_error, _kind}}, req, state = %{pid: pid}) do
    error = %RPCError{status: GRPC.Status.unknown(), message: "Internal Server Error"}
    trailers = HTTP2.server_trailers(error.status, error.message)
    exit_handler(pid, :error)
    req = send_error_trailers(req, trailers)
    {:stop, req, state}
  end

  def info({:EXIT, pid, {reason, stacktrace}}, req, state = %{pid: pid}) do
    Logger.error(Exception.format(:error, reason, stacktrace))
    error = %RPCError{status: GRPC.Status.unknown(), message: "Internal Server Error"}
    trailers = HTTP2.server_trailers(error.status, error.message)
    exit_handler(pid, reason)
    req = send_error_trailers(req, trailers)
    {:stop, req, state}
  end

  def terminate(reason, _req, %{pid: pid}) when is_pid(pid) do
    exit_handler(pid, reason)
    :ok
  end

  def terminate(reason, _req, _state) do
    :ok
  end

  ## Helpers

  defp handle_message(data, state = %{message_buffer: buffer, server_opts: server_opts}) do
    %{request_module: req_mod, service: service_mod, module: server_mod, response_module: resp_mod} = server_opts
    buffer = buffer <> data
    new_state = %{state | message_buffer: buffer}

    if(GRPC.Message.complete?(buffer)) do
      raw_message = GRPC.Message.from_data(buffer)
      formed_message = %{__struct__: ^req_mod} = service_mod.unmarshal(req_mod, raw_message)
      new_state = %{new_state | message_buffer: <<>>}
      {:ok, formed_message, new_state}
    else
      {:ok, nil, new_state}
    end
  end

  defp marshal_response(%{service: service_mod, response_module: resp_mod}, response = %{__struct__: resp_mod}) do
    raw_message = service_mod.marshal(resp_mod, response)
    {:ok, data, _size} = GRPC.Message.to_data(raw_message, %{iolist: true})
    {:ok, data}
  end

  defp send_response_over_the_wire(req, response_data) do
    req = check_sent_resp(req)
    :cowboy_req.stream_body(response_data, :nofin, req)
    req
  end

  defp send_trailers_over_the_wire(req, trailers, state) do
    req = check_sent_resp(req)
    :cowboy_req.stream_trailers(trailers, req)

    case Map.get(state, :pid, nil) do
      nil ->
        req

      pid when is_pid(pid) ->
        Process.exit(pid, :kill)
        req
    end
  end

  defp check_sent_resp(%{has_sent_resp: _} = req) do
    req
  end

  defp check_sent_resp(req) do
    :cowboy_req.stream_reply(200, req)
  end

  defp send_error_trailers(%{has_sent_resp: _} = req, trailers) do
    :cowboy_req.stream_trailers(trailers, req)
  end

  defp send_error_trailers(req, trailers) do
    :cowboy_req.reply(200, trailers, req)
  end

  def exit_handler(pid, reason) do
    if Process.alive?(pid) do
      Process.exit(pid, reason)
    end
  end

end