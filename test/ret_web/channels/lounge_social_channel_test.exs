defmodule RetWeb.LoungeSocialChannelTest do
  # The social relay needs PubSub and Presence, but never a database connection.
  # This suite also runs with `mix run --no-start` in an isolated BEAM instance.
  use ExUnit.Case, async: false

  alias RetWeb.{HubChannel, Presence}
  alias Phoenix.Socket.Broadcast

  @sender "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @target "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @id "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @invite %{"type" => "invite", "id" => @id, "to" => @target, "pose" => "hug"}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Ret.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Ret.PubSub})
    end

    unless Process.whereis(Presence) do
      start_supervised!(Presence)
    end

    :ok
  end

  setup do
    topic = "hub:social-test-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Ret.PubSub, topic)
    {:ok, _} = Presence.track(self(), topic, @target, %{presence: :room})

    socket = %Phoenix.Socket{
      topic: topic,
      pubsub_server: Ret.PubSub,
      joined: true,
      channel_pid: self(),
      transport_pid: self(),
      serializer: Phoenix.Socket.V2.JSONSerializer,
      join_ref: "social-test",
      assigns: %{
        session_id: @sender,
        presence: :room,
        blocked_session_ids: %{},
        blocked_by_session_ids: %{},
        has_blocks: false
      }
    }

    {:ok, socket: socket}
  end

  test "acknowledgement and sender echo carry the same server identity and timestamp", %{
    socket: socket
  } do
    before = System.system_time(:millisecond)

    assert {:reply, {:ok, event}, _socket} =
             HubChannel.handle_in("lounge_social:send", @invite, socket)

    assert event["from_session_id"] == @sender
    assert event["at"] >= before
    assert event["at"] <= System.system_time(:millisecond)
    assert Map.drop(event, ["from_session_id", "at"]) == @invite

    topic = socket.topic
    assert_receive %Broadcast{topic: ^topic, event: "lounge_social:event", payload: ^event}
    assert {:noreply, ^socket} = HubChannel.handle_out("lounge_social:event", event, socket)
    assert_receive {:socket_push, :text, encoded}

    assert ["social-test", nil, ^topic, "lounge_social:event", ^event] =
             Jason.decode!(IO.iodata_to_binary(encoded))
  end

  test "the existing Presence API returns atom metadata and filters lobby or absent targets", %{
    socket: socket
  } do
    assert %{metas: [%{presence: :room}]} = Presence.list(socket)[@target]
    {:ok, _} = Presence.update(self(), socket.topic, @target, %{presence: :lobby})

    assert {:reply, {:error, %{reason: "invalid_target"}}, _} =
             HubChannel.handle_in("lounge_social:send", @invite, socket)

    :ok = Presence.untrack(self(), socket.topic, @target)
    {:ok, _} = Presence.track(self(), socket.topic <> "-other-room", @target, %{presence: :room})

    assert {:reply, {:error, %{reason: "invalid_target"}}, _} =
             HubChannel.handle_in("lounge_social:send", @invite, socket)

    refute_receive %Broadcast{event: "lounge_social:event"}
  end

  test "lobby sockets cannot send or receive social events", %{socket: socket} do
    socket = Phoenix.Socket.assign(socket, :presence, :lobby)
    state = %{"type" => "state", "touch" => false}

    assert {:reply, {:error, %{reason: "not_entered"}}, _} =
             HubChannel.handle_in("lounge_social:send", state, socket)

    event = Ret.LoungeSocial.stamp(@invite, @target, 123)
    assert {:noreply, ^socket} = HubChannel.handle_out("lounge_social:event", event, socket)
    refute_receive {:socket_push, _, _}
  end

  test "existing block broadcasts update both directions and prevent social sends", %{
    socket: socket
  } do
    {:noreply, blocking_socket} =
      HubChannel.handle_in("block", %{"session_id" => @target}, socket)

    assert blocking_socket.assigns.blocked_session_ids[@target]

    assert {:reply, {:error, %{reason: "blocked"}}, _} =
             HubChannel.handle_in("lounge_social:send", @invite, blocking_socket)

    # The existing block event deliberately has a string target key and atom sender key.
    block_event = %{"session_id" => @sender, :from_session_id => @target}
    {:noreply, blocked_socket} = HubChannel.handle_out("block", block_event, socket)
    assert blocked_socket.assigns.blocked_by_session_ids[@target]

    assert {:reply, {:error, %{reason: "blocked"}}, _} =
             HubChannel.handle_in("lounge_social:send", @invite, blocked_socket)

    {:noreply, unblocked_socket} = HubChannel.handle_out("unblock", block_event, blocked_socket)

    assert {:reply, {:ok, _}, _} =
             HubChannel.handle_in("lounge_social:send", @invite, unblocked_socket)
  end

  test "outgoing events retain string keys and suppress either blocked actor", %{socket: socket} do
    event = Ret.LoungeSocial.stamp(@invite, @sender, 123)

    for actor <- [@sender, @target], field <- [:blocked_session_ids, :blocked_by_session_ids] do
      blocked_socket = Phoenix.Socket.assign(socket, field, %{actor => true})

      assert {:noreply, ^blocked_socket} =
               HubChannel.handle_out("lounge_social:event", event, blocked_socket)
    end

    refute_receive {:socket_push, _, _}
    assert {:noreply, ^socket} = HubChannel.handle_out("lounge_social:event", event, socket)
    assert_receive {:socket_push, :text, encoded}
    assert [_, _, _, "lounge_social:event", ^event] = Jason.decode!(IO.iodata_to_binary(encoded))
  end

  test "invalid or spoofed payloads are acknowledged as errors and never broadcast", %{
    socket: socket
  } do
    for payload <- [Map.put(@invite, "from_session_id", @target), Map.put(@invite, "at", 1), nil] do
      assert {:reply, {:error, %{reason: "invalid_payload"}}, _} =
               HubChannel.handle_in("lounge_social:send", payload, socket)
    end

    refute_receive %Broadcast{event: "lounge_social:event"}
  end

  test "socket limits survive the reply while Stop can immediately follow an action", %{
    socket: socket
  } do
    assert {:reply, {:ok, _}, socket} =
             HubChannel.handle_in("lounge_social:send", @invite, socket)

    assert {:reply, {:error, %{reason: "rate_limited"}}, socket} =
             HubChannel.handle_in("lounge_social:send", @invite, socket)

    stop = %{"type" => "stop", "id" => @id, "to" => @target}

    assert {:reply, {:ok, %{"type" => "stop"}}, _} =
             HubChannel.handle_in("lounge_social:send", stop, socket)
  end

  test "stopping a solo emote immediately is acknowledged and broadcast", %{socket: socket} do
    dance = %{"type" => "emote", "name" => "dance"}
    none = %{"type" => "emote", "name" => "none"}
    assert {:reply, {:ok, _}, socket} = HubChannel.handle_in("lounge_social:send", dance, socket)
    assert {:reply, {:ok, event}, _} = HubChannel.handle_in("lounge_social:send", none, socket)
    assert event["name"] == "none"
    assert_receive %Broadcast{event: "lounge_social:event", payload: ^event}
  end
end
