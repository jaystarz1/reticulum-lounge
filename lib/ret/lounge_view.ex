defmodule Ret.LoungeView do
  @moduledoc "Room-scoped, durable time of day. Only this JSON key is changed."

  def get(hub_id) do
    %{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        Ret.Repo,
        "SELECT user_data->'lounge_view' FROM hubs WHERE hub_id = $1",
        [hub_id]
      )

    state || %{"name" => "day", "revision" => 0}
  end

  def set(hub_id, name) when name in ["day", "dusk", "night"] do
    # PostgreSQL serializes simultaneous updates of this row. Do not perform a
    # read-modify-write of the entire user_data map or trust a client clock.
    %{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        Ret.Repo,
        """
        UPDATE hubs SET user_data = jsonb_set(COALESCE(user_data, '{}'::jsonb),
          '{lounge_view}', jsonb_build_object('name', $1::text, 'revision',
            COALESCE((user_data#>>'{lounge_view,revision}')::bigint, 0) + 1))
        WHERE hub_id = $2 RETURNING user_data->'lounge_view'
        """,
        [name, hub_id]
      )

    state
  end
end
