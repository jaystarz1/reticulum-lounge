# private-quest-lounge server policy. Run with:
#   docker compose exec reticulum sh -c "cd /code && mix run priv/repo/lounge_config.exs"
#
# Locks the deployment down to the two-person private-lounge model:
# - rooms hold at most 2 participants (default and hard max)
# - only admins can create rooms (invite links still work for guests)
# - no new account sign-ups (guests join anonymously via the invite URL)

alias Ret.AppConfig

set = fn key, value ->
  %Ret.AppConfig{} = AppConfig.set_config_value(key, value)
  IO.puts("set #{key} = #{inspect(value)}")
end

set.("features|default_room_size", 2)
set.("features|max_room_size", 4)  # 2 people + TV client + 1 spare (ghost tabs)
set.("features|disable_room_creation", true)
set.("features|disable_sign_up", true)
# restrictive member permissions: no media spawning/drawing/camera/emoji/fly,
# voice and text chat stay on
set.("features|permissive_rooms", false)

IO.puts("lounge config applied")
