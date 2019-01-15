defmodule Random.RandomRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  @type t :: %__MODULE__{
          upperBound: integer
        }
  defstruct [:upperBound]

  field :upperBound, 1, type: :int32
end

defmodule Random.RandomResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  @type t :: %__MODULE__{
          randomNumber: integer
        }
  defstruct [:randomNumber]

  field :randomNumber, 1, type: :int32
end

defmodule Random.RandomService.Service do
  @moduledoc false
  use GRPC.Service, name: "Random.RandomService"

  rpc :GenerateNumber, Random.RandomRequest, Random.RandomResponse
  rpc :GenerateManyNumbers, stream(Random.RandomRequest), stream(Random.RandomResponse)
end

defmodule Random.RandomService.Stub do
  @moduledoc false
  use GRPC.Stub, service: Random.RandomService.Service
end
