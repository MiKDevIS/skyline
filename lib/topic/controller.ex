
defmodule Skyline.Topic.Controller do
  @moduledoc """
  Implements the controller pipeline responsible for handling 
  publish and subscribe messages.
  
  ## The pipeline
  The goal of a controller is to receive a request and invoke the desired
  action. The whole flow of the controller is managed by a single pipeline:
      defmodule UserController do
        use Skyline.Topic.Controller
        require Logger
        pipe :log_message, "before action"
        def publish(conn, _params) do
          Logger.debug "publish/2"
          conn
        end
        defp log_message(conn, msg) do
          Logger.debug msg
          conn
        end
      end
  When invoked, this pipeline will print:
      before action
      show/2
  As any other pipeline, we can halt at any step by returning
  {:close_connection, reason} where reason can be an exception or a string.
  If we change `log_message/2` to:
      def log_message(conn, msg) do
        Logger.debug msg
        {:close_connection, "Halt pipe"}
      end
  it will print only:
      before action
  As the rest of the pipeline (the action and the after action pipe)
  will never be invoked.
  ## Guards
  `pipe/2` supports guards, allowing a developer to configure a pipe to only
  run in some particular action:
      pipe :log_message, "before publish" when action == :publish
  The first pipe will run only when action is publish.
  Those guards work like regular Elixir guards and the only variables accessible
  in the guard are `conn`, the `action` as an atom and the `controller` as an
  alias.
  
  ## Controllers are pipes
  Like routers, controllers are pipes, but they are wired to dispatch
  to a particular function which is called an action.
  For example, the route:
      subscribe "/users/:id", UserController
  will invoke `UserController` as a pipe:
      UserController.call(conn, :subscribe)
  which will trigger the pipe pipeline and which will eventually
  invoke the inner action pipe that dispatches to the `show/2`
  function in the `UserController`.
  As controllers are pipes, they implement both `init/1` and
  `call/2`, and it also provides a function named `action/2`
  which is responsible for dispatching the appropriate action
  after the pipe stack (and is also overridable).
  """
  
  @doc false
  defmacro __using__(_) do
    quote do
     
      import Skyline.Topic.Controller
      import Skyline.Topic.Pipe
      Module.register_attribute(__MODULE__, :pipes, accumulate: true)
      
      @behaviour Skyline.Topic.Pipe
      
      @before_compile Skyline.Topic.Controller

      @doc false
      def init(action) when is_atom(action) do
        action
      end

      @doc false
      def call(conn, action) do
        conn = update_in conn.private,
                 &(&1 |> Map.put(:skyline_controller, __MODULE__)
                      |> Map.put(:skyline_action, action))

        controller_pipeline(conn, action)
      end

      @doc false
      def action(%{private: %{skyline_action: action}} = conn, _options) do
        apply(__MODULE__, action, [conn, conn.params])
      end

      defoverridable [init: 1, call: 2, action: 2]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    action = {:action, [], true}
    pipes  = [action|Module.get_attribute(env.module, :pipes)]
    {conn, body} = Skyline.Topic.Pipe.compile(env, pipes, log_on_halt: :debug)

    quote do
      defoverridable [action: 2]

      def action(conn, opts) do
        try do
          super(conn, opts)
        catch
          kind, reason ->
            Skyline.Topic.Controller.__catch__(
              kind, reason, __MODULE__, conn.private.skyline_action, System.stacktrace
            )
        end
      end

      defp controller_pipeline(unquote(conn), var!(action)) do
        var!(conn) = unquote(conn)
        var!(controller) = __MODULE__
        _ = var!(conn)
        _ = var!(controller)
        _ = var!(action)

        unquote(body)
      end
    end
  end

  @doc false
  def __catch__(:error, :function_clause, controller, action,
                [{controller, action, [%Skyline.Topic.Conn{} | _], _loc} | _] = stack) do
    args = [controller: controller, action: action]
    reraise Phoenix.ActionClauseError, args, stack
  end
  def __catch__(kind, reason, _controller, _action, stack) do
    :erlang.raise(kind, reason, stack)
  end

  @doc """
  Stores a pipe to be executed as part of the pipe pipeline.
  """
  defmacro pipe(pipe)

  defmacro pipe({:when, _, [pipe, guards]}), do:
    pipe(pipe, [], guards)

  defmacro pipe(pipe), do:
    pipe(pipe, [], true)

  @doc """
  Stores a pipe with the given options to be executed as part of
  the pipe pipeline.
  """
  defmacro pipe(pipe, opts)

  defmacro pipe(pipe, {:when, _, [opts, guards]}), do:
    pipe(pipe, opts, guards)

  defmacro pipe(pipe, opts), do:
    pipe(pipe, opts, true)

  defp pipe(pipe, opts, guards) do
    quote do
      @pipes {unquote(pipe), unquote(opts), unquote(Macro.escape(guards))}
    end
  end
end
