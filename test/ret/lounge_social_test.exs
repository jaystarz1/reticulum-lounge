defmodule Ret.LoungeSocialTest do
  use ExUnit.Case, async: true
  alias Ret.LoungeSocial, as: Social

  @sender "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @target "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @id "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @targeted %{"id" => @id, "to" => @target}
  @present %{@target => %{metas: [%{presence: :room}]}}

  test "accepts only the complete typed wire contract" do
    payloads =
      [
        %{"type" => "state", "touch" => true},
        %{"type" => "state", "touch" => false}
      ] ++
        for_names("emote", ~w(wave clap dance sit none)) ++
        for_names("expression", ~w(neutral smile sad surprise wink)) ++
        Enum.map(~w(hug hold_hands sit_together slow_dance), fn pose ->
          Map.merge(@targeted, %{"type" => "invite", "pose" => pose})
        end) ++
        Enum.map(~w(accept stop), &Map.put(@targeted, "type", &1)) ++
        for side <- ~w(left right), zone <- ~w(hand arm shoulder face) do
          Map.merge(@targeted, %{"type" => "touch", "side" => side, "zone" => zone})
        end

    Enum.each(payloads, fn payload -> assert Social.validate(payload) == {:ok, payload} end)
  end

  test "rejects spoofed identity/time, extra or atom keys, unknown values and malformed payloads" do
    state = %{"type" => "state", "touch" => true}

    invalid = [
      Map.put(state, "from_session_id", @target),
      Map.put(state, "at", 123),
      Map.put(state, :touch, true),
      Map.put(state, "extra", nil),
      %{"type" => "state", "touch" => "true"},
      %{"type" => "emote", "name" => "hug"},
      %{"type" => "expression", "name" => "tracked"},
      %{"type" => "unknown"},
      %{"type" => "emote"},
      %{},
      nil,
      [],
      "state"
    ]

    Enum.each(invalid, &assert(Social.validate(&1) == {:error, :invalid_payload}))
  end

  test "targeted messages require bounded UUID identifiers and allowed pose/side/zone" do
    invite = Map.merge(@targeted, %{"type" => "invite", "pose" => "hug"})
    touch = Map.merge(@targeted, %{"type" => "touch", "side" => "left", "zone" => "hand"})

    invalid = [
      Map.put(invite, "id", String.duplicate("a", 100_000)),
      Map.put(invite, "to", String.duplicate("b", 100_000)),
      Map.put(invite, "id", "not-a-uuid"),
      Map.put(invite, "to", 5),
      Map.put(invite, "id", nil),
      Map.put(invite, "pose", "custom"),
      Map.put(touch, "side", "both"),
      Map.put(touch, "zone", "custom"),
      Map.put(touch, "strength", 1.0),
      Map.delete(touch, "side")
    ]

    Enum.each(invalid, &assert(Social.validate(&1) == {:error, :invalid_payload}))
  end

  test "requires an entered sender and entered different target in this room" do
    invite = Map.merge(@targeted, %{"type" => "invite", "pose" => "hug"})
    assert Social.authorize(invite, @sender, :room, @present, %{}, %{}) == :ok
    assert Social.authorize(invite, @sender, :lobby, @present, %{}, %{}) == {:error, :not_entered}
    assert Social.authorize(invite, @sender, :room, %{}, %{}, %{}) == {:error, :invalid_target}

    lobby = %{@target => %{metas: [%{presence: :lobby}]}}
    assert Social.authorize(invite, @sender, :room, lobby, %{}, %{}) == {:error, :invalid_target}

    self = Map.put(invite, "to", @sender)
    assert Social.authorize(self, @sender, :room, @present, %{}, %{}) == {:error, :invalid_target}

    state = %{"type" => "state", "touch" => false}
    assert Social.authorize(state, @sender, :room, %{}, %{}, %{}) == :ok
  end

  test "either direction of blocking rejects targeted sends and filters both actors for observers" do
    invite = Map.merge(@targeted, %{"type" => "invite", "pose" => "hug"})
    blocked = %{@target => true}
    assert Social.authorize(invite, @sender, :room, @present, blocked, %{}) == {:error, :blocked}
    assert Social.authorize(invite, @sender, :room, @present, %{}, blocked) == {:error, :blocked}

    event = Social.stamp(invite, @sender, 123)
    assert Social.visible?(event, :room, %{}, %{})
    refute Social.visible?(event, :lobby, %{}, %{})

    for actor <- [@sender, @target] do
      refute Social.visible?(event, :room, %{actor => true}, %{})
      refute Social.visible?(event, :room, %{}, %{actor => true})
    end
  end

  test "state, action and touch limits use independent monotonic buckets" do
    for {type, interval} <- [{"state", 1_000}, {"invite", 250}, {"touch", 200}] do
      payload = %{"type" => type}
      assert {:ok, limits} = Social.rate_limit(%{}, payload, -5_000)

      assert {:error, :rate_limited, limits} =
               Social.rate_limit(limits, payload, -5_001 + interval)

      assert {:ok, _} = Social.rate_limit(limits, payload, -5_000 + interval)
    end

    assert {:ok, limits} = Social.rate_limit(%{}, %{"type" => "state"}, 0)
    assert {:ok, limits} = Social.rate_limit(limits, %{"type" => "emote"}, 0)
    assert {:ok, limits} = Social.rate_limit(limits, %{"type" => "touch"}, 0)
    assert {:error, :rate_limited, _} = Social.rate_limit(limits, %{"type" => "accept"}, 249)
  end

  test "Stop bypasses action cooldown, has reserved capacity and is still flood bounded" do
    {:ok, limits} = Social.rate_limit(%{}, %{"type" => "invite"}, 0)
    assert {:ok, _} = Social.rate_limit(limits, %{"type" => "stop"}, 0)

    limits =
      Enum.reduce(1..12, %{}, fn _, limits ->
        case Social.rate_limit(limits, %{"type" => "state"}, 0) do
          {:ok, limits} -> limits
          {:error, :rate_limited, limits} -> limits
        end
      end)

    assert length(limits.recent) == 12
    assert {:error, :rate_limited, limits} = Social.rate_limit(limits, %{"type" => "emote"}, 0)

    limits =
      Enum.reduce(1..8, limits, fn _, limits ->
        assert {:ok, limits} = Social.rate_limit(limits, %{"type" => "stop"}, 0)
        limits
      end)

    assert {:error, :rate_limited, limits} = Social.rate_limit(limits, %{"type" => "stop"}, 0)
    assert length(limits.recent) == 20
    assert {:ok, _} = Social.rate_limit(limits, %{"type" => "stop"}, 1_000)
  end

  test "server stamp preserves the validated payload and supplies identity and time" do
    payload = %{"type" => "emote", "name" => "wave"}

    assert Social.stamp(payload, @sender, 1_234) ==
             Map.merge(payload, %{"from_session_id" => @sender, "at" => 1_234})
  end

  test "solo emote none shares Stop's cooldown bypass and reserved flood capacity" do
    none = %{"type" => "emote", "name" => "none"}
    {:ok, limits} = Social.rate_limit(%{}, %{"type" => "emote", "name" => "dance"}, 0)
    assert {:ok, limits} = Social.rate_limit(limits, none, 1)
    assert limits.action == 0
    assert limits.stop == 1

    limits = %{recent: List.duplicate(0, 12), action: 0}

    limits =
      Enum.reduce(1..8, limits, fn _, limits ->
        assert {:ok, limits} = Social.rate_limit(limits, none, 1)
        limits
      end)

    assert {:error, :rate_limited, limits} = Social.rate_limit(limits, none, 1)
    assert length(limits.recent) == 20
    assert {:ok, _} = Social.rate_limit(limits, none, 1_001)
  end

  defp for_names(type, names), do: Enum.map(names, &%{"type" => type, "name" => &1})
end
