defmodule Ret.GmailWebhookMailer do
  @moduledoc """
  private-quest-lounge Swoosh adapter that delivers mail through the operator's
  Google Apps Script webhook (the same backend the google-workspace MCP uses),
  so magic-link emails are sent by the operator's own Gmail account. Configure
  with `webhook_url`. The webhook sends as the authenticated Google account;
  the Swoosh `from` field is ignored.
  """
  @behaviour Swoosh.Adapter

  @impl true
  def deliver(%Swoosh.Email{} = email, config) do
    url = Keyword.fetch!(config, :webhook_url)
    {_name, to} = email.to |> List.first()
    body = email.html_body || (email.text_body || "") |> String.replace("\n", "<br>")

    payload =
      Poison.encode!(%{
        action: "createAndSend",
        to: to,
        subject: email.subject,
        body: body
      })

    case HTTPoison.post(url, payload, [{"Content-Type", "application/json"}],
           hackney: [follow_redirect: true],
           recv_timeout: 30_000
         ) do
      {:ok, %HTTPoison.Response{status_code: code, body: resp}} when code in 200..399 ->
        {:ok, %{response: resp |> String.slice(0, 200)}}

      {:ok, %HTTPoison.Response{status_code: code, body: resp}} ->
        {:error, {:http_error, code, resp |> String.slice(0, 500)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def deliver_many(emails, config) do
    results = Enum.map(emails, &deliver(&1, config))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, r} -> r end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(config) do
    if Keyword.get(config, :webhook_url), do: :ok, else: raise(ArgumentError, "webhook_url required")
  end

  @impl true
  def validate_dependency, do: :ok
end
