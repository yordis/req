defmodule Req.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Finch, name: Req.Finch}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Req do
  @moduledoc """
  """

  defstruct [
    :request,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{}
  ]

  ## High-level API

  @doc """
  Makes a GET request.
  """
  def get!(url, opts \\ []) do
    case request(:get, url, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Makes an HTTP request.
  """
  def request(method, url, opts \\ []) do
    method
    |> build(url, opts)
    |> add_request_steps([
      &default_headers/1
    ])
    |> add_response_steps([
      &decode/1
    ])
    |> run()
  end

  ## Low-level API

  @doc """
  Builds a Req pipeline.
  """
  def build(method, url, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    headers = Keyword.get(opts, :headers, [])
    request = Finch.build(method, url, headers, body)

    %Req{
      request: request
    }
  end

  @doc """
  Runs a pipeline.
  """
  def run(state) do
    result =
      Enum.reduce_while(state.request_steps, state.request, fn step, acc ->
        case run(step, acc, state) do
          %Finch.Request{} = request ->
            {:cont, request}

          %Finch.Response{} = response ->
            {:halt, {:response, response}}

          %{__exception__: true} = exception ->
            {:halt, {:error, exception}}

          {:halt, result} ->
            {:halt, {:halt, result}}
        end
      end)

    case result do
      %Finch.Request{} = request ->
        run_request(request, state)

      {:response, response} ->
        run_response(response, state)

      {:error, exception} ->
        run_error(exception, state)

      {:halt, result} ->
        halt(result)
    end
  end

  defp run_request(request, state) do
    case Finch.request(request, Req.Finch) do
      {:ok, response} ->
        run_response(response, state)

      {:error, exception} ->
        run_error(exception, state)
    end
  end

  defp run_response(response, state) do
    Enum.reduce_while(state.response_steps, {:ok, response}, fn step, {:ok, acc} ->
      case run(step, acc, state) do
        %Finch.Response{} = response ->
          {:cont, {:ok, response}}

        %{__exception__: true} = exception ->
          {:halt, run_error(exception, state)}

        {:halt, result} ->
          {:halt, halt(result)}
      end
    end)
  end

  defp run_error(exception, state) do
    Enum.reduce_while(state.error_steps, {:error, exception}, fn step, {:error, acc} ->
      case run(step, acc, state) do
        %{__exception__: true} = exception ->
          {:cont, {:error, exception}}

        %Finch.Response{} = response ->
          {:halt, run_response(response, state)}

        {:halt, result} ->
          {:halt, halt(result)}
      end
    end)
  end

  defp run(fun, request_or_response_or_exception, _state) when is_function(fun, 1) do
    fun.(request_or_response_or_exception)
  end

  defp run(fun, request_or_response_or_exception, state) when is_function(fun, 2) do
    fun.(request_or_response_or_exception, state)
  end

  @doc """
  Assigns a new private `key` and `value`.
  """
  def put_private(state, key, value) do
    update_in(state.private, &Map.put(&1, key, value))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(state, key, default \\ nil) do
    Map.get(state.private, key, default)
  end

  defp halt(%Finch.Response{} = response) do
    {:ok, response}
  end

  defp halt(%{__exception__: true} = exception) do
    {:error, exception}
  end

  ## Request steps

  def default_headers(request) do
    put_new_header(request, "user-agent", "req/0.1.0-dev")
  end

  ## Response steps

  @doc """
  Decodes a response body based on its `content-type`.
  """
  def decode(response) do
    case List.keyfind(response.headers, "content-type", 0) do
      {_, "application/json" <> _} ->
        update_in(response.body, &Jason.decode!/1)

      _ ->
        response
    end
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  """
  def retry(response_or_exception, state) do
    max_attempts = 2
    attempt = get_private(state, :retry_attempt, 0)

    if attempt < max_attempts do
      state = put_private(state, :retry_attempt, attempt + 1)
      {_, result} = run(%{state | request_steps: []})
      {:halt, result}
    else
      response_or_exception
    end
  end

  ## Utilities

  def add_request_steps(state, steps) do
    update_in(state.request_steps, &(&1 ++ steps))
  end

  def add_response_steps(state, steps) do
    update_in(state.response_steps, &(&1 ++ steps))
  end

  def add_error_steps(state, steps) do
    update_in(state.error_steps, &(&1 ++ steps))
  end

  defp put_new_header(struct, name, value) do
    if Enum.any?(struct.headers, fn {key, _} -> String.downcase(key) == name end) do
      struct
    else
      update_in(struct.headers, &[{name, value} | &1])
    end
  end
end