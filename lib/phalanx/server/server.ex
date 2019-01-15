defmodule Phalanx.Server do

  @callback initialize(path :: String.t) :: :ok | {:ok, pid} | {:error, :not_found}

  @callback meta(path :: String.t) :: term()

  @callback request_message(path :: String.t, message :: term, request_finished :: atom(),  stream_info :: map) :: {:ok, term()} | {:ok, :noreply} | {:error, term()}
end