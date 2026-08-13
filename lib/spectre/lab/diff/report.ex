defmodule Spectre.Lab.Diff.Report do
  @moduledoc "Stable data-only report for two verified checkpoint timelines."

  @enforce_keys [
    :status,
    :common_prefix_count,
    :common_head_revision,
    :left_revisions,
    :right_revisions,
    :left_only,
    :right_only,
    :changed_revisions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: :identical | :left_prefix | :right_prefix | :diverged,
          common_prefix_count: non_neg_integer(),
          common_head_revision: non_neg_integer() | nil,
          left_revisions: [non_neg_integer()],
          right_revisions: [non_neg_integer()],
          left_only: [non_neg_integer()],
          right_only: [non_neg_integer()],
          changed_revisions: [non_neg_integer()]
        }
end
