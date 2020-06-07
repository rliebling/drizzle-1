defmodule Drizzle.Scheduler do
  use GenServer

  alias Drizzle.{Schedule, TodaysEvents}

  @schedule_config %{
    #        duration        variance   frequency                   trigger_clause
    #                                                        offset      after/before  condition
    zone1: {{5,  :minutes}, :fixed,    {:daily},           {{3, :hours},   :before, :sunrise}},
    zone2: {{20, :minutes}, :variable, {:every, 2, :days}, {{3.5, :hours}, :after,  :midnight}},
    zone3: {{15, :minutes}, :variable, {},                 {:chain,        :after,  :zone2}},
    zone4: {{15, :minutes}, :variable, {},                 {:chain,        :after,  :zone3}},
    zone5: {{25, :minutes}, :variable, {},                 {:chain,        :after,  :zone4}},
    zone6: {{25, :minutes}, :variable, {},                 {:chain,        :after,  :zone5}},
    zone7: {{20, :minutes}, :variable, {:every, 3, :days}, {:exactly,      :at,     :noon}},
    zone8: {{10, :minutes}, :fixed,    {:on, [:mon, :fri]}, {{30, :minutes}, :after, :sunset}}
  }

  # state = %{
  #   astro: %{latitude: 38.0621576, longitude: 23.8155186},
  #   schedule_config: %{
  #     zone1: {{5, :minutes}, :fixed, {:daily},
  #      {{3, :hours}, :before, :sunrise}},
  #     zone2: {{20, :minutes}, :variable, {:every, 2, :days},
  #      {{3.5, :hours}, :after, :midnight}},
  #     zone3: {{15, :minutes}, :variable, {},
  #      {:chain, :after, :zone2}},
  #     zone7: {{20, :minutes}, :variable, {},
  #      {:exactly, :at, :noon}},
  #     zone8: {{10, :minutes}, :fixed, {:on, [:mon, :fri]},
  #      {{30, :minutes}, :after, :sunset}}
  #   }
  # }
  # r(Drizzle.Scheduler);  state |> Drizzle.Scheduler.todays_tasks

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: DrizzleScheduler)
  end

  def init(state) do
    IO.puts("Starting scheduler")
    #tzinfo = timezone_info()
    {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
    #
    GenServer.cast(DrizzleScheduler, :update_cron)
    {:ok, Map.merge(state, %{
      astro: Application.get_env(:drizzle, :location),
      schedule_config: @schedule_config,
      supervisor: pid
    })}
  end

  @doc "recalculate sunrise and sunset every midnight"
  def handle_info(:update_cron, state) do
    {:noreply, put_in(state, [:schedule], generate_schedule(state))}
  end

  def generate_schedule(state) do
    %{}
  end

  def todays_tasks(state) do
    #state.schedule_config
    #factor = Drizzle.Weather.weather_adjustment_factor() |>IO.inspect(label: "factor")
    factor = 0.25
    @schedule_config
    |> Enum.map(fn {zone, {duration, variance, frequency, trigger_clause} = all} ->
      dur = duration
        |> parse_duration()
        |> apply_variance(variance, factor)
      freq = frequency
        |> freqexpr()
      trig = trigger_clause
        |> parse_trigger(state)
        |> evtexpr()
      next = next_occurrence(freq, trig)
        case trigger_clause do
          #{:chain, _, _} -> nil
          _ -> {zone, %{dur: dur, freq: freq, trig: trig, next: next}} #|> IO.inspect(label: "===========>")
        end
    end)
    #|> Enum.filter(&(!is_nil(&1)))
  end

  # TODO: do we want :fixed to mean "ignore weather data", or simply turn off the zone when rain is expected?
  # uncommenting the 1st clause will block ALL zones when weather adjustment factor is 0, regardless of variance requested
  #defp apply_variance(_duration, _variance, 0), do: 0
  defp apply_variance(duration, variance, factor) do
    Timex.Duration.to_milliseconds(duration) * (if variance == :fixed do 1 else factor end)
  end

  # convert duration tuple to Timex.Duration eg {1, :hours} ==> #<Duration(PT1H)>
  def parse_duration({num, units}) when is_number(num) and units in [:hours, :minutes, :seconds] do
    apply(Timex.Duration, String.to_atom("from_#{units}"), [num]) #|> IO.inspect(label: "offset")
  end

  # cron expression for frequency ==> day of week
  defp freqexpr({:daily}),            do: %{dow: "*"}
  defp freqexpr({:every, x, :days}),  do: %{dow_divisor: x}
  defp freqexpr({:on, arr_of_days}),  do: %{dow: Enum.map(arr_of_days, &(Timex.day_to_num(&1)))}
  defp freqexpr({}), do: %{}
  # cron expression for triggers ==> hour+minute
  defp parse_trigger({:chain,   :after, zone}, _state), do: zone #FIXME, pass scb so that zone1 deact triggers zone2 act
  defp parse_trigger({:exactly, :at,  event}, state) when event in [:midnight, :sunrise, :noon, :sunset], do: evttime(event, state)
  defp parse_trigger({offset, :before, event}, state), do: evttime(event, state) |> Timex.subtract(offset |> parse_duration())
  defp parse_trigger({offset, :after,  event}, state), do: evttime(event, state) |> Timex.add(offset |> parse_duration())

  # get UTC datetimes for today's astronomical events, only the hour+min part is used
  defp evttime(:midnight, state), do: Timex.shift(evttime(:noon, state), hours: 12)
  defp evttime(:sunrise,  state), do: with {:ok, ret} <- Solarex.Sun.rise(Timex.today(), state.astro.latitude, state.astro.longitude), do: ret |> Timex.Timezone.convert("Etc/UTC")
  defp evttime(:noon,     state), do: with {:ok, ret} <- Solarex.Sun.noon(Timex.today(), state.astro.latitude, state.astro.longitude), do: ret |> Timex.Timezone.convert("Etc/UTC")
  defp evttime(:sunset,   state), do: with {:ok, ret} <- Solarex.Sun.set(Timex.today(), state.astro.latitude, state.astro.longitude), do: ret |> Timex.Timezone.convert("Etc/UTC")

  defp evtexpr(%DateTime{} = dt), do: %{hour: dt.hour, min: dt.minute}
  defp evtexpr(_), do: %{}

  def next_occurrence(%{dow: "*"}, trig) do
    join_date_time(Timex.today, trig) |> shift_to_future()
  end
  def next_occurrence(%{dow: [arr]}, trig) do
    {year, weeknum, _dow} = Timex.iso_triplet(Timex.now)
    for week_advance <- 0..1, day_of_week <- arr do
      {year, weeknum+week_advance, day_of_week} |> join_date_time(trig)
    end |> Enum.find(fn(candidate) -> candidate |> Timex.after?(Timex.now()) end)
  end
  def next_occurrence(%{dow_divisor: dd}, trig) do
    for days_advance <- 0..dd do
      Date.utc_today |> join_date_time(trig) |> shift_to_future(days_advance)
    end |> Enum.find(fn(candidate) -> candidate |> Timex.after?(Timex.now()) end)
  end
  def next_occurrence(%{}, %{}), do: nil

  defp join_date_time({y, m, d}, time) do
    {{y, m, d}, {time.hour, time.min, 0}} |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
  end
  defp join_date_time(date, time) do
    {:ok, merged} = NaiveDateTime.new(date, Time.from_erl!({time.hour, time.min, 0}))
    merged |> DateTime.from_naive!("Etc/UTC")
  end

  # shift a datetime 24 hours ahead if we're past it
  defp shift_to_future(dt, days \\ 1) do
    dt |> Timex.shift(days: (
      if dt |> Timex.before?(Timex.now()) do days else 0 end
    ))
  end

end
