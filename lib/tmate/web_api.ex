defmodule Tmate.WebApi do
  require Logger
  use Plug.Router
  use Plug.ErrorHandler

  def cowboy_dispatch(webhooks) do
    :cowboy_router.compile([{:_, [
      {"/ws/session/:stoken", Tmate.WebSocket, []},
      {:_, Plug.Cowboy.Handler, {__MODULE__, [webhooks: webhooks]}},
    ]}])
  end

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug Plug.Logger, log: :debug
  plug :dispatch, builder_opts()

  defmodule AuthError do
    defexception message: "Forbidden", plug_status: 403
  end

  post "/master_api/report_active_sessions" do
    ensure_master_auth!(conn.body_params)
    report_active_sessions(conn.body_params, opts)
    send_resp(conn, 200, "{}")
  end

  defp ensure_master_auth!(%{"auth_key" => auth_key}) do
    {:ok, ws_options} = Application.fetch_env(:tmate, :websocket)
    if !Plug.Crypto.secure_compare(auth_key, ws_options[:wsapi_key]) do
      raise AuthError
    end
  end
  defp ensure_master_auth!(_), do: raise AuthError

  defp report_active_sessions(%{"sessions" => session_ids}, opts) when is_list(session_ids) do
    stale_ids = Enum.flat_map(session_ids, fn id ->
      case Tmate.SessionRegistry.get_session_by_id(Tmate.SessionRegistry, id) do
        :error -> [id]
        _ -> []
      end
    end)
    prune_master_sessions(stale_ids, opts)
  end

  defp prune_master_sessions([], _opts), do: nil
  defp prune_master_sessions(session_ids, opts) do
    webhooks = opts[:webhooks]

    pids = Tmate.Webhook.Many.start_links(webhooks)

    timestamp = DateTime.utc_now
    Enum.each(session_ids, fn id ->
      Tmate.Webhook.Many.emit_event(webhooks, pids,
        :session_disconnect, id, timestamp, %{}, max_attempts: 1)
    end)

    Tmate.Webhook.Many.exit(pids, :normal)
  end

  match _ do
    send_resp(conn, 404, ":(")
  end
end
