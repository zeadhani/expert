defmodule Engine.CodeIntelligence.HeexComponentTest do
  use ExUnit.Case, async: true

  alias Engine.CodeIntelligence.HeexComponent
  alias Forge.Document

  defp create_document(content) do
    Document.new("file:///test.heex", content, 1, "phoenix-heex")
  end

  describe "component_at/2" do
    test "extracts aliased component" do
      document = create_document("<Button.button>Click me</Button.button>")

      assert {:ok, {:aliased, "Button", "button"}} = HeexComponent.component_at(document, {1, 10})
    end

    test "extracts imported component" do
      document = create_document("<.card>Content</.card>")

      assert {:ok, {:imported, "card"}} = HeexComponent.component_at(document, {1, 3})
    end

    test "handles component with attributes" do
      document = create_document(~s(<Button.primary type="submit">Save</Button.primary>))

      assert {:ok, {:aliased, "Button", "primary"}} =
               HeexComponent.component_at(document, {1, 15})
    end

    test "handles imported component with attributes" do
      document = create_document(~s(<.input name="email" type="text" />))

      assert {:ok, {:imported, "input"}} = HeexComponent.component_at(document, {1, 3})
    end

    test "returns error when not on a component" do
      document = create_document("<div>Hello</div>")

      assert {:error, :not_component} = HeexComponent.component_at(document, {1, 5})
    end

    test "returns error when cursor is not in a tag" do
      document = create_document("Just some text")

      assert {:error, :not_component} = HeexComponent.component_at(document, {1, 5})
    end

    test "extracts component with multiple module segments" do
      document = create_document("<MyApp.Components.Button.primary />")

      assert {:ok, {:aliased, "MyApp.Components.Button", "primary"}} =
               HeexComponent.component_at(document, {1, 10})
    end
  end
end
