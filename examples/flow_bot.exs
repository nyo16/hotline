# Flow Bot — multi-step conversation flows with registration, feedback, and settings.
#
# Demonstrates:
#   - Linear steps with validation and /skip
#   - Inline keyboard choices with callback queries
#   - Numeric validation and free-text input
#   - Multiple flows, /cancel, /status, /help
#
# Usage:
#   HOTLINE_TOKEN="your-bot-token" mix run examples/flow_bot.exs

# --- Registration Flow ---

defmodule FlowBot.Flows.Registration do
  use Hotline.Flow

  step(:name, prompt: "Let's get you registered!\n\nWhat's your name?")

  step(:email,
    prompt: fn ctx ->
      "Nice to meet you, #{ctx.data.name}! What's your email?\n\nSend /skip to skip."
    end
  )

  step(:confirm,
    prompt: fn ctx ->
      email = ctx.data[:email] || "skipped"

      "Please confirm your registration:\n\n" <>
        "  Name: #{ctx.data.name}\n" <>
        "  Email: #{email}\n\n" <>
        "Tap a button below."
    end,
    keyboard: [
      [%{text: "Confirm", callback_data: "yes"}, %{text: "Start over", callback_data: "no"}]
    ]
  )

  @impl true
  def handle_input(:name, %{message: %{text: name}}, _ctx) when byte_size(name) >= 2 do
    {:next, store: %{name: String.trim(name)}}
  end

  def handle_input(:name, _, _ctx), do: {:retry, "Name must be at least 2 characters. Try again:"}

  def handle_input(:email, %{message: %{text: "/skip"}}, _ctx) do
    {:next, store: %{email: nil}}
  end

  def handle_input(:email, %{message: %{text: email}}, _ctx) do
    if String.contains?(email, "@") and String.contains?(email, "."),
      do: {:next, store: %{email: String.trim(email)}},
      else: {:retry, "That doesn't look like a valid email. Try again or send /skip."}
  end

  def handle_input(:email, _, _ctx), do: {:retry, "Please send your email or /skip."}

  def handle_input(:confirm, %{callback_query: %{data: "yes"}}, _ctx), do: :done

  def handle_input(:confirm, %{callback_query: %{data: "no"}}, _ctx) do
    {:goto, :name, reset: true}
  end

  def handle_input(:confirm, _, _ctx), do: {:retry, "Please use the buttons above."}

  @impl true
  def on_done(ctx) do
    email = ctx.data[:email] || "not provided"

    Hotline.send_message(%{
      chat_id: ctx.chat_id,
      text: "Registration complete!\n\nName: #{ctx.data.name}\nEmail: #{email}"
    })
  end
end

# --- Feedback Flow ---

defmodule FlowBot.Flows.Feedback do
  use Hotline.Flow

  step(:rating,
    prompt: "How would you rate your experience? (1-5)",
    keyboard: [
      [
        %{text: "1", callback_data: "1"},
        %{text: "2", callback_data: "2"},
        %{text: "3", callback_data: "3"},
        %{text: "4", callback_data: "4"},
        %{text: "5", callback_data: "5"}
      ]
    ]
  )

  step(:comment,
    prompt: fn ctx ->
      stars = String.duplicate("⭐", ctx.data.rating)
      "#{stars}\n\nAny additional comments? Send /skip if none."
    end
  )

  @impl true
  def handle_input(:rating, %{callback_query: %{data: data}}, _ctx) do
    case Integer.parse(data) do
      {n, ""} when n in 1..5 -> {:next, store: %{rating: n}}
      _ -> {:retry, "Please tap a rating button (1-5)."}
    end
  end

  def handle_input(:rating, %{message: %{text: text}}, _ctx) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n in 1..5 -> {:next, store: %{rating: n}}
      _ -> {:retry, "Please enter a number between 1 and 5."}
    end
  end

  def handle_input(:rating, _, _ctx), do: {:retry, "Please rate 1-5."}

  def handle_input(:comment, %{message: %{text: "/skip"}}, _ctx) do
    {:done, :no_comment}
  end

  def handle_input(:comment, %{message: %{text: comment}}, _ctx) do
    {:done, comment}
  end

  def handle_input(:comment, _, _ctx), do: {:retry, "Please type your comment or send /skip."}

  @impl true
  def on_done(ctx) do
    Hotline.send_message(%{
      chat_id: ctx.chat_id,
      text: "Thank you for your feedback! 🙏"
    })
  end
end

# --- Settings Flow ---

defmodule FlowBot.Flows.Settings do
  use Hotline.Flow

  step(:language,
    prompt: "Choose your language:",
    keyboard: [
      [%{text: "🇬🇧 English", callback_data: "en"}, %{text: "🇪🇸 Spanish", callback_data: "es"}],
      [%{text: "🇫🇷 French", callback_data: "fr"}, %{text: "🇩🇪 German", callback_data: "de"}]
    ]
  )

  step(:notifications,
    prompt: "Would you like to receive notifications?",
    keyboard: [
      [%{text: "Yes, notify me", callback_data: "on"}, %{text: "No thanks", callback_data: "off"}]
    ]
  )

  @impl true
  def handle_input(:language, %{callback_query: %{data: lang}}, _ctx)
      when lang in ~w(en es fr de) do
    {:next, store: %{language: lang}}
  end

  def handle_input(:language, _, _ctx), do: {:retry, "Please pick a language from the buttons."}

  def handle_input(:notifications, %{callback_query: %{data: pref}}, _ctx)
      when pref in ~w(on off) do
    {:done, %{notifications: pref == "on"}}
  end

  def handle_input(:notifications, _, _ctx), do: {:retry, "Please use the buttons above."}

  @impl true
  def on_done(ctx) do
    lang_names = %{"en" => "English", "es" => "Spanish", "fr" => "French", "de" => "German"}
    lang = lang_names[ctx.data.language] || ctx.data.language
    notif = if ctx.data[:__result__][:notifications], do: "enabled", else: "disabled"

    Hotline.send_message(%{
      chat_id: ctx.chat_id,
      text: "Settings saved!\n\nLanguage: #{lang}\nNotifications: #{notif}"
    })
  end
end

# --- Bot ---

defmodule FlowBot do
  use Hotline.Bot

  @commands """
  Available commands:

  /register — Start the registration flow
  /feedback — Share your feedback (rating + comment)
  /settings — Configure language and notifications
  /cancel   — Cancel the current flow
  /status   — Check if a flow is active
  /help     — Show this help message
  """

  @impl Hotline.Bot
  def handle_update(%{message: %{text: "/start", chat: %{id: chat_id}}}, state) do
    Hotline.send_message(%{
      chat_id: chat_id,
      text: "Welcome to FlowBot! 👋\n\n#{@commands}"
    })

    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/help", chat: %{id: chat_id}}}, state) do
    Hotline.send_message(%{chat_id: chat_id, text: @commands})
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/register", chat: %{id: chat_id}}}, state) do
    start_or_warn(chat_id, FlowBot.Flows.Registration)
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/feedback", chat: %{id: chat_id}}}, state) do
    start_or_warn(chat_id, FlowBot.Flows.Feedback)
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/settings", chat: %{id: chat_id}}}, state) do
    start_or_warn(chat_id, FlowBot.Flows.Settings)
    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/cancel", chat: %{id: chat_id}}}, state) do
    case Hotline.Flow.Engine.cancel_flow(chat_id) do
      :ok ->
        Hotline.send_message(%{chat_id: chat_id, text: "Flow cancelled."})

      {:error, :no_flow} ->
        Hotline.send_message(%{chat_id: chat_id, text: "No active flow to cancel."})
    end

    {:noreply, state}
  end

  def handle_update(%{message: %{text: "/status", chat: %{id: chat_id}}}, state) do
    msg =
      if Hotline.Flow.Engine.active_flow?(chat_id),
        do: "You have an active flow. Send /cancel to stop it.",
        else: "No active flow. Try /register, /feedback, or /settings."

    Hotline.send_message(%{chat_id: chat_id, text: msg})
    {:noreply, state}
  end

  def handle_update(%{message: %{text: text, chat: %{id: chat_id}}} = update, state)
      when is_binary(text) do
    unless Hotline.Flow.Engine.handles_update?(update) do
      Hotline.send_message(%{
        chat_id: chat_id,
        text: "I don't understand that. Try /help for available commands."
      })
    end

    {:noreply, state}
  end

  def handle_update(_update, state), do: {:noreply, state}

  defp start_or_warn(chat_id, flow_module) do
    case Hotline.Flow.Engine.start_flow(chat_id, flow_module) do
      :ok ->
        :ok

      {:error, :flow_active} ->
        Hotline.send_message(%{
          chat_id: chat_id,
          text: "You already have an active flow. Send /cancel first."
        })
    end
  end
end

# --- Supervision Tree ---

children = [
  {Hotline.Poller, []},
  {Hotline.Flow.Engine, []},
  {FlowBot, []}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

IO.puts("""
Flow bot running! Send these commands to your bot in Telegram:

  /start    — Welcome message
  /register — Registration flow (name → email → confirm)
  /feedback — Feedback flow (rating → comment)
  /settings — Settings flow (language → notifications)
  /cancel   — Cancel active flow
  /status   — Check flow status
  /help     — Show commands

Press Ctrl+C to stop.
""")

Process.sleep(:infinity)
