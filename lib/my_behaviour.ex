defmodule MyBehaviour do
    @callback vital_fun() :: any
    @callback non_vital_fun() :: any
    @macrocallback non_vital_macro(arg :: any) :: Macro.t
    @optional_callbacks non_vital_fun: 0, non_vital_macro: 1
  end