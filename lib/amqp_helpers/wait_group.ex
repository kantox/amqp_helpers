defmodule AMQPHelpers.WaitGroup do
  @moduledoc false

  @type delivery_tag :: {non_neg_integer(), binary(), pid()}
  @type message_ids :: %{binary() => {non_neg_integer(), pid()}}
  @type t :: %__MODULE__{delivery_tags: [delivery_tag()], message_ids: message_ids()}

  defstruct delivery_tags: [], message_ids: %{}

  @spec new :: t()
  def new, do: %__MODULE__{}

  @doc """
  Removes an entry or a list of entries.

  Given a message id, `delete/2` removes the entry with the given message id.
  Or, given a deliver tag, `delete/2` removes all entries with a delivery tag
  lower than the given delivery tag.

  ## Examples

      iex> AMQPHelpers.WaitGroup.new()
      ...> |> AMQPHelpers.WaitGroup.put(1, "foo", self())
      ...> |> AMQPHelpers.WaitGroup.delete("foo")
      ...> |> AMQPHelpers.WaitGroup.fetch("foo")
      :error

      iex> AMQPHelpers.WaitGroup.new()
      ...> |> AMQPHelpers.WaitGroup.put(1, "foo", self())
      ...> |> AMQPHelpers.WaitGroup.put(2, "bar", self())
      ...> |> AMQPHelpers.WaitGroup.delete("foo")
      ...> |> AMQPHelpers.WaitGroup.fetch("bar")
      {:ok, [{2, self()}]}

      iex> AMQPHelpers.WaitGroup.new()
      ...> |> AMQPHelpers.WaitGroup.put(1, "foo", self())
      ...> |> AMQPHelpers.WaitGroup.put(2, "bar", self())
      ...> |> AMQPHelpers.WaitGroup.delete(2)
      ...> |> AMQPHelpers.WaitGroup.fetch(1)
      :error

  """
  @spec delete(t(), binary() | non_neg_integer()) :: t()
  def delete(wait_group, message_id) when is_binary(message_id) do
    %__MODULE__{
      delivery_tags: Enum.reject(wait_group.delivery_tags, &match?({_, ^message_id, _}, &1)),
      message_ids: Map.delete(wait_group.message_ids, message_id)
    }
  end

  def delete(wait_group, delivery_tag) when is_integer(delivery_tag) do
    Enum.reduce_while(wait_group.delivery_tags, wait_group, fn item, acc ->
      {item_delivery_tag, item_message_id, _pid} = item

      if item_delivery_tag <= delivery_tag do
        {:cont,
         %__MODULE__{
           delivery_tags: List.delete_at(acc.delivery_tags, 0),
           message_ids: Map.delete(acc.message_ids, item_message_id)
         }}
      else
        {:halt, acc}
      end
    end)
  end

  @doc """
  Retrieves an entry or a list of entries.

  Given a message id, `fetch/2` gets the `{delivery_tag, pid}` with the given
  message id. If a deliver tag is given, then `fetch/2` returns a list of
  `{message_id, pid}` lower than the given delivery tag.

  ## Examples

      iex> AMQPHelpers.WaitGroup.fetch(AMQPHelpers.WaitGroup.new(), "foo")
      :error

      iex> AMQPHelpers.WaitGroup.fetch(AMQPHelpers.WaitGroup.new(), 9001)
      :error

      iex> AMQPHelpers.WaitGroup.new()
      ...> |> AMQPHelpers.WaitGroup.put(1, "foo", self())
      ...> |> AMQPHelpers.WaitGroup.fetch("foo")
      {:ok, [{1, self()}]}

      iex> AMQPHelpers.WaitGroup.new()
      ...> |> AMQPHelpers.WaitGroup.put(1, "foo", self())
      ...> |> AMQPHelpers.WaitGroup.put(2, "bar", self())
      ...> |> AMQPHelpers.WaitGroup.fetch(2)
      {:ok, [{"foo", self()}, {"bar", self()}]}

  """
  @spec fetch(t(), binary() | non_neg_integer()) ::
          {:ok, [{non_neg_integer(), pid()} | {binary(), pid()}]} | :error
  def fetch(wait_group, message_id) when is_binary(message_id) do
    with {:ok, entry} <- Map.fetch(wait_group.message_ids, message_id) do
      {:ok, [entry]}
    end
  end

  def fetch(wait_group, delivery_tag) when is_integer(delivery_tag) do
    result =
      wait_group.delivery_tags
      |> Stream.take_while(fn {dt, _, _} -> dt <= delivery_tag end)
      |> Enum.map(fn {_delivery_tag, message_id, pid} -> {message_id, pid} end)

    if Enum.empty?(result), do: :error, else: {:ok, result}
  end

  @spec put(t(), non_neg_integer(), binary(), pid()) :: t()
  def put(wait_group, delivery_tag, message_id, pid) do
    delivery_tags = insert_delivery_tag(wait_group.delivery_tags, {delivery_tag, message_id, pid})
    message_ids = Map.put(wait_group.message_ids, message_id, {delivery_tag, pid})

    %__MODULE__{delivery_tags: delivery_tags, message_ids: message_ids}
  end

  @spec insert_delivery_tag([delivery_tag()], delivery_tag()) :: [delivery_tag()]
  defp insert_delivery_tag([], delivery_tag), do: [delivery_tag]

  defp insert_delivery_tag([lhs = {lt, _, _} | tail], rhs = {rt, _, _}) when lt < rt do
    [lhs | insert_delivery_tag(tail, rhs)]
  end

  defp insert_delivery_tag(list, delivery_tag), do: [delivery_tag | list]
end
