defmodule Ret.LoungeSocial do
  @moduledoc """
  Stateless validation for the room's ephemeral social relay.

  Session identity and event time are added by HubChannel, never accepted from a
  client. This relay does not grant consent: clients must match an unexpired
  invitation and an explicit acceptance from its recipient before starting a
  paired pose, and validate mutual touch opt-in before producing haptics.
  """

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @emotes ~w(wave clap dance sit none)
  @expressions ~w(neutral smile sad surprise wink)
  @poses ~w(hug hold_hands sit_together slow_dance)
  @zones ~w(hand arm shoulder face)

  def validate(%{"type" => "state", "touch" => touch} = payload)
      when is_boolean(touch),
      do: exact_keys(payload, ~w(type touch))

  def validate(%{"type" => "emote", "name" => name} = payload) when name in @emotes,
    do: exact_keys(payload, ~w(type name))

  def validate(%{"type" => "expression", "name" => name} = payload)
      when name in @expressions,
      do: exact_keys(payload, ~w(type name))

  def validate(%{"type" => "invite", "id" => id, "to" => to, "pose" => pose} = payload)
      when pose in @poses,
      do: targeted(payload, id, to, ~w(type id to pose))

  def validate(%{"type" => type, "id" => id, "to" => to} = payload)
      when type in ["accept", "stop"],
      do: targeted(payload, id, to, ~w(type id to))

  def validate(
        %{"type" => "touch", "id" => id, "to" => to, "side" => side, "zone" => zone} = payload
      )
      when side in ["left", "right"] and zone in @zones,
      do: targeted(payload, id, to, ~w(type id to side zone))

  def validate(_), do: {:error, :invalid_payload}

  def authorize(payload, sender, presence, presences, blocked, blocked_by) do
    target = payload["to"]

    cond do
      presence != :room ->
        {:error, :not_entered}

      is_nil(target) ->
        :ok

      target == sender or not entered?(presences[target]) ->
        {:error, :invalid_target}

      blocked?(target, blocked, blocked_by) ->
        {:error, :blocked}

      true ->
        :ok
    end
  end

  # Phoenix Presence metadata is supplied by the server's presence_meta_for_socket.
  # Merely joining the hub leaves presence at :lobby; events:entered sets :room.
  def entered?(%{metas: metas}) when is_list(metas),
    do: Enum.any?(metas, &match?(%{presence: :room}, &1))

  def entered?(_), do: false

  def visible?(payload, presence, blocked, blocked_by) do
    presence == :room and
      not blocked?(payload["from_session_id"], blocked, blocked_by) and
      not blocked?(payload["to"], blocked, blocked_by)
  end

  @doc "Enforce monotonic per-socket limits, reserving eight flood slots for Stop."
  def rate_limit(limits, payload, now) do
    recent = Enum.filter(Map.get(limits, :recent, []), &(&1 > now - 1_000))
    type = if is_map(payload), do: payload["type"], else: nil
    stop? = type == "stop" or (type == "emote" and payload["name"] == "none")
    limits = Map.put(limits, :recent, recent)

    if length(recent) >= if(stop?, do: 20, else: 12) do
      {:error, :rate_limited, limits}
    else
      # Even malformed or too-frequent attempts consume bounded flood capacity.
      limits = Map.put(limits, :recent, [now | recent])
      {bucket, interval} = if stop?, do: {:stop, 0}, else: rate_bucket(type)
      previous = limits[bucket]

      if stop? or is_nil(previous) or now - previous >= interval do
        {:ok, Map.put(limits, bucket, now)}
      else
        {:error, :rate_limited, limits}
      end
    end
  end

  def stamp(payload, sender, at),
    do: Map.merge(payload, %{"from_session_id" => sender, "at" => at})

  defp rate_bucket("state"), do: {:state, 1_000}
  defp rate_bucket("touch"), do: {:touch, 200}
  defp rate_bucket("stop"), do: {:stop, 0}
  defp rate_bucket(_), do: {:action, 250}

  defp exact_keys(payload, keys) do
    if map_size(payload) == length(keys) and Enum.all?(keys, &Map.has_key?(payload, &1)),
      do: {:ok, payload},
      else: {:error, :invalid_payload}
  end

  defp targeted(payload, id, to, keys) do
    if uuid?(id) and uuid?(to),
      do: exact_keys(payload, keys),
      else: {:error, :invalid_payload}
  end

  defp uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@uuid, value)

  defp blocked?(session, blocked, blocked_by),
    do: Map.has_key?(blocked, session) or Map.has_key?(blocked_by, session)
end
