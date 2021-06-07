defmodule Tmate.Webhook do
  use GenServer
  require Logger

  defmodule Event do
    @enforce_keys [:type, :entity_id, :timestamp, :generation]
    @derive Jason.Encoder
    defstruct @enforce_keys ++ [:userdata, params: %{}]
  end

  # We use a genserver per session because we don't want to block the session
  # process, but we still want to keep the events ordered.
  def start_link(webhook, opts \\ []) do
    GenServer.start_link(__MODULE__, webhook, opts)
  end

  def init(webhook) do
    {:ok, webhook_options} = Application.fetch_env(:tmate, :webhook)
    max_attempts = webhook_options[:max_attempts]
    initial_retry_interval = webhook_options[:initial_retry_interval]

    state = %{url: webhook[:url], userdata: webhook[:userdata],
              max_attempts: max_attempts, initial_retry_interval: initial_retry_interval}
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  def emit_event(pid, event) do
    GenServer.cast(pid, {:emit_event, event})
  end

  def handle_cast({:emit_event, event}, state) do
    do_emit_event(event, state)
    {:noreply, state}
  end

  defp do_emit_event(event, state) do
    event = %{event | userdata: state.userdata}
    payload = Jason.encode!(event)
    post_event(state, event.type, payload, 1)
  end

  defp post_event(state, event_type, payload, num_attempts) do
    url = state.url
    Logger.debug("Sending the following payload to webhook: #{payload}")
    case post_event_once(url, payload) do
      :ok ->
        Logger.info("Webhook succeeded on #{url}")
      {:error, reason} ->
        if num_attempts == state.max_attempts do
          Logger.error "Webhook fail on #{url} - Dropping event :#{event_type} (#{inspect(reason)})"
          :error
        else
          if num_attempts == 1 do
            Logger.warn "Webhook fail on #{url} - Retrying event :#{event_type} (#{inspect(reason)})"
          end

          :timer.sleep(state.initial_retry_interval * Kernel.trunc(:math.pow(2, num_attempts-1)))
          post_event(state, event_type, payload, num_attempts + 1)
        end
    end
  end

  defp post_event_once(url, payload) do
    headers = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]
    # We need force_redirect: true, otherwise, post data doesn't get reposted.
    case HTTPoison.post(url, payload, headers, hackney: [pool: :default, force_redirect: true], follow_redirect: true) do
      {:ok, %HTTPoison.Response{status_code: status_code}} when status_code >= 200 and status_code  < 300 ->
        :ok
      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        {:error, "status=#{status_code}"}
      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  defmodule Many do
    def start_links(webhooks) do
      Enum.map(webhooks, fn {webhook_mod, webhook_opts} ->
        {:ok, pid} = webhook_mod.start_link(webhook_opts)
        pid
      end)
    end

    def emit_event(webhooks, pids, event) do
      Enum.zip(webhooks, pids)
      |> Enum.each(fn {{webhook_mod, _webhook_opts}, pid} ->
        webhook_mod.emit_event(pid, event)
      end)
    end
  end
end
