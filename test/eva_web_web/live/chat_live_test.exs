defmodule EvaWebWeb.ChatLiveTest do
  use EvaWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EvaWeb.Sessions

  # These tests read the real ~/.eva session index but never create or delete anything there.

  describe "index" do
    test "renders the shell with no session selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#sidebar")
      assert has_element?(view, "#session-list")
      assert has_element?(view, "#new-project")
      assert has_element?(view, "#composer")
      # No transcript container until a session is opened.
      refute has_element?(view, "#messages")
    end

    test "the composer is disabled with no session selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#chat-input[disabled]")
      assert has_element?(view, "#send-button[disabled]")
    end

    test "lists every stored session with a delete control", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for group <- Sessions.list_grouped(), session <- group.sessions do
        assert has_element?(view, "#session-#{session.id}")
        assert has_element?(view, "#confirm-delete-session-#{session.id}")
      end
    end
  end

  describe "show" do
    test "redirects to the index when the session is unknown", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/sessions/does-not-exist")

      assert flash["error"] =~ "no longer exists"
    end
  end

  describe "new session form" do
    test "offers a provider for every one Eva knows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "start_new_session")

      assert html =~ ~s|id="new-session-form"|

      for provider <- EvaWeb.Providers.all() do
        assert has_element?(view, ~s|#new-session-provider option[value="#{provider.name}"]|)
      end
    end

    test "an unreachable provider leaves the model as a text field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "start_new_session")
      html = render_async(view)

      # config/test.exs points the default provider at a closed port.
      assert html =~ "Could not reach"
      assert has_element?(view, ~s|input#new-session-model|)
      refute has_element?(view, ~s|select#new-session-model|)
    end

    test "the form closes again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_click(view, "start_new_session")
      assert has_element?(view, "#new-session-form")

      render_click(view, "cancel_new_session")
      refute has_element?(view, "#new-session-form")
    end
  end

  describe "sidebar" do
    test "session links point at their own route", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      case Sessions.list_grouped() do
        [%{sessions: [session | _]} | _] ->
          assert has_element?(view, ~s|a[href="/sessions/#{session.id}"]|)

        _ ->
          assert has_element?(view, "#session-list")
      end
    end
  end
end
