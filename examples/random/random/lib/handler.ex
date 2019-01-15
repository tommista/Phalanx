defmodule Random.Handler do
  @behaviour Phalanx.Server

  use GenServer

  ## Test Runner

  def start() do
    {:ok, channel} = GRPC.Stub.connect("localhost:50051")

    request = Random.RandomRequest.new(%{upperBound: 10})

    {:ok, response = %Random.RandomResponse{}} = Random.RandomService.Stub.generate_number(channel, request)

    response
  end

  def start_stream(num_requests) do
    {:ok, channel} = GRPC.Stub.connect("localhost:50051")

    request = Random.RandomRequest.new(%{upperBound: 10})
    client_stream = Random.RandomService.Stub.generate_many_numbers(channel, timeout: 86400000)

    client_stream =
      Enum.reduce(1..num_requests, client_stream, fn
        ^num_requests, cs ->
          IO.inspect("Sending fin request")
          GRPC.Stub.send_request(client_stream, request, end_stream: true)

        _num, cs ->
          :timer.sleep(1000)
          IO.inspect("Sending no fin request")
          GRPC.Stub.send_request(client_stream, request, end_stream: false)
      end)


    {:ok, response_stream} = GRPC.Stub.recv(client_stream)

    response_stream
    |> Stream.map(fn {:ok, response = %Random.RandomResponse{}} -> response |> IO.inspect() end)
    |> Enum.take(num_requests)
  end

  ## Phalanx.Server Calls

  def initialize(path) do
    GenServer.start_link(__MODULE__, {self(), path})
  end

  def meta("/Random.RandomService/GenerateNumber") do
    %{
      service: Random.RandomService.Service,
      request_module: Random.RandomRequest,
      response_module: Random.RandomResponse,
      request_stream?: false,
      response_stream?: false
    }
  end

  def meta("/Random.RandomService/GenerateManyNumbers") do
    %{
      service: Random.RandomService.Service,
      request_module: Random.RandomRequest,
      response_module: Random.RandomResponse,
      request_stream?: true,
      response_stream?: true
    }
  end

  def request_message("/Random.RandomService/GenerateNumber", message, _req_finished?, %{pid: pid}) do
    GenServer.call(pid, {:new_message, message})
  end

  def request_message("/Random.RandomService/GenerateManyNumbers", message, req_finished?, %{pid: pid}) do
    IO.inspect(req_finished?, label: "Is the request done streaming?")

    send(pid, {:new_message, message, req_finished?})
    {:ok, :noreply}
  end

  ## Genserver Calls

  def init({parent, _path}) do
    {:ok, %{parent: parent, sent: false}}
  end

  def handle_call({:new_message, %Random.RandomRequest{upperBound: upper_bound}}, _from, state) do
    response = Random.RandomResponse.new(%{randomNumber: :rand.uniform(upper_bound)})

    {:reply, {:ok, response}, state}
  end

  def handle_info({:new_message, %Random.RandomRequest{upperBound: upper_bound}, req_finished?}, state = %{parent: pid}) do
    response = Random.RandomResponse.new(%{randomNumber: :rand.uniform(upper_bound)})

    if(req_finished?) do
      Phalanx.Handler.send_reply(pid, response, :fin)
    else
      Phalanx.Handler.send_reply(pid, response)
    end

    {:noreply, state}
  end

end