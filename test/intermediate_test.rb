require "test_helper"

class IntermediateTest < Minitest::Spec
  Right = Class.new # Trailblazer::Activity::Right
  Left = Class.new # Trailblazer::Activity::Right
  PassFast = Class.new # Trailblazer::Activity::Right

  it "compiles {Schema} from intermediate and implementation, with two ends" do
    skip # till Dev::Introspect is available
    # generated by the editor or a specific DSL.
    # TODO: unique {id}
    # Intermediate shall not contain actual object references, since it might be generated.
    intermediate = Inter.new(
      {
        Inter::TaskRef(:a) => [Inter::Out(:success, :b), Inter::Out(:failure, :c)],
        Inter::TaskRef(:b) => [Inter::Out(:success, :d), Inter::Out(:failure, :c)],
        Inter::TaskRef(:c) => [Inter::Out(:success, "End.failure"), Inter::Out(:failure, "End.failure")],
        Inter::TaskRef(:d) => [Inter::Out(:success, "End.success"), Inter::Out(:failure, "End.success")],
        Inter::TaskRef("End.success", stop_event: true) => [Inter::Out(:success, nil)], # this is how the End semantic is defined.
        Inter::TaskRef("End.failure", stop_event: true) => [Inter::Out(:failure, nil)]
      },
      ["End.success", "End.failure"],
      [:a]
    ) # start

    a_extension_1 = ->(config:, **) { config.merge(a1: true) }
    a_extension_2 = ->(config:, **) { config.merge(a2: yo)   }
    b_extension_1 = ->(config:, **) { config.merge(b1: false) }

    implementation = {
      :a => Schema::Implementation::Task(Implementing.method(:a), [Activity::Output(Right,       :success), Activity::Output(Left, :failure)],        [a_extension_1, a_extension_2]),
      :b => Schema::Implementation::Task(Implementing.method(:b), [Activity::Output("B/success", :success), Activity::Output("B/failure", :failure)], [b_extension_1]),
      :c => Schema::Implementation::Task(Implementing.method(:c), [Activity::Output(Right,       :success), Activity::Output(Left, :failure)]),
      :d => Schema::Implementation::Task(Implementing.method(:d), [Activity::Output("D/success", :success), Activity::Output(Left, :failure)]),
      "End.success" => Schema::Implementation::Task(Implementing::Success, [Activity::Output(Implementing::Success, :success)]), # DISCUSS: End has one Output, signal is itself?
      "End.failure" => Schema::Implementation::Task(Implementing::Failure, [Activity::Output(Implementing::Failure, :failure)])
    }

    schema = Inter.(intermediate, implementation)

    cct = Trailblazer::Developer::Render::Circuit.(schema)

    expect(cct).must_equal %{
#<Method: #<Module:0x>.a>
 {IntermediateTest::Right} => #<Method: #<Module:0x>.b>
 {IntermediateTest::Left} => #<Method: #<Module:0x>.c>
#<Method: #<Module:0x>.b>
 {B/success} => #<Method: #<Module:0x>.d>
 {B/failure} => #<Method: #<Module:0x>.c>
#<Method: #<Module:0x>.c>
 {IntermediateTest::Right} => #<End/:failure>
 {IntermediateTest::Left} => #<End/:failure>
#<Method: #<Module:0x>.d>
 {D/success} => #<End/:success>
 {IntermediateTest::Left} => #<End/:success>
#<End/:success>

#<End/:failure>
}
    expect(schema[:outputs].inspect).must_equal %{[#<struct Trailblazer::Activity::Output signal=#<Trailblazer::Activity::End semantic=:success>, semantic=:success>, #<struct Trailblazer::Activity::Output signal=#<Trailblazer::Activity::End semantic=:failure>, semantic=:failure>]}

    # :extension API
    #   test it works with and without [bla_ext], and more than one per line
    expect(schema[:config].inspect).must_equal %{{:wrap_static=>{}, :a1=>true, :a2=>:yo, :b1=>false}}
  end

  def implementation(c_extensions)
    {
      :C => Schema::Implementation::Task(c = Implementing.method(:c), [Activity::Output(Activity::Right, :success)],                  c_extensions),
      "End.success" => Schema::Implementation::Task(_es = Implementing::Success, [Activity::Output(Implementing::Success, :success)], [])
    }
  end

  it "start and stop can be arbitrary" do
    skip # till Dev::Introspect is available
    # D returns "D/stop" signal.
    module D
      def self.d_end((ctx, flow_options), *)
        ctx[:seq] << :d
        return "D/stop", [ctx, flow_options]
      end
    end

    intermediate =
      Inter.new(
        {
          Inter::TaskRef("Start.default")                 => [Inter::Out(:success, :C)],
          Inter::TaskRef(:C)                              => [Inter::Out(:success, :D)],
          Inter::TaskRef(:D)                              => [Inter::Out(:win,     :E)],
          Inter::TaskRef(:E)                              => [Inter::Out(:success, "End.success")],
          Inter::TaskRef("End.success", stop_event: true) => [Inter::Out(:success, nil)]
        },
        # arbitrary start and end event.
        [:D, "End.success"], # end events
        [:C] # start
      )

    implementation =
      {
        "Start.default" => Schema::Implementation::Task(Implementing::Start, [Activity::Output(Activity::Right, :success)], []),
        :C => Schema::Implementation::Task(Implementing.method(:c), [Activity::Output(Activity::Right, :success)], []),
        :D => Schema::Implementation::Task(D.method(:d_end),        [Activity::Output("D/stop", :win)], []),
        :E => Schema::Implementation::Task(Implementing.method(:f), [Activity::Output(Activity::Right, :success)], []),
        "End.success" => Schema::Implementation::Task(Implementing::Success, [Activity::Output(Implementing::Success, :success)], [])
      }

    schema = Inter.(intermediate, implementation)

    expect(schema[:outputs].inspect).must_equal %{[#<struct Trailblazer::Activity::Output signal="D/stop", semantic=:win>, #<struct Trailblazer::Activity::Output signal=#<Trailblazer::Activity::End semantic=:success>, semantic=:success>]}

    assert_circuit(
      schema, %{
#<Start/:default>
 {Trailblazer::Activity::Right} => #<Method: #<Module:0x>.c>
#<Method: #<Module:0x>.c>
 {Trailblazer::Activity::Right} => #<Method: IntermediateTest::D.d_end>
#<Method: IntermediateTest::D.d_end>

#<Method: #<Module:0x>.f>
 {Trailblazer::Activity::Right} => #<End/:success>
#<End/:success>
}
    )

    signal, (ctx,) = schema[:circuit].([{seq: []}])

    expect(signal.inspect).must_equal %{"D/stop"}
    # stop at :D.
    expect(ctx.inspect).must_equal %{{:seq=>[:c, :d]}}
  end

  describe ":extension API: Config" do
    let(:intermediate) do
      Inter.new(
        {
          Inter::TaskRef(:C)                              => [Inter::Out(:success, "End.success")],
          Inter::TaskRef("End.success", stop_event: true) => [Inter::Out(:success, nil)]
        },
        ["End.success"],
        [:C] # start
      )
    end

    def implementation(c_extensions)
      {
        :C => Schema::Implementation::Task(c = Implementing.method(:c), [Activity::Output(Activity::Right, :success)],                  c_extensions),
        "End.success" => Schema::Implementation::Task(_es = Implementing::Success, [Activity::Output(Implementing::Success, :success)], [])
      }
    end

    # Accessor API

    it "doesn't allow mutations" do
      ext_a = ->(config:, **) { config[:a] = "bla" }

      exception = Object.const_defined?(:FrozenError) ? FrozenError : RuntimeError # < Ruby 2.5

      assert_raises exception do
        Inter.(intermediate, implementation([ext_a]))
      end
    end

    it "allows using the {Config} API" do
      ext_a = ->(config:, **)       { config.merge(a: "bla") }
      ext_b = ->(config:, **)       { config.merge(b: "blubb") }
      ext_d = ->(config:, id:, **)  { config.merge(id => 1) }              # provides :id
      ext_e = ->(config:, **)       { config.merge(e: config[:C] + 1) } # allows reading new {Config} instance.

      schema = Inter.(intermediate, implementation([ext_a, ext_b, ext_d, ext_e]))

      expect(schema[:config].to_h.inspect).must_equal %{{:wrap_static=>{}, :a=>\"bla\", :b=>\"blubb\", :C=>1, :e=>2}}
    end

  # {Implementation.call()} allows to pass {config} data
    describe "{Implementation.call()}" do
      it "accepts {config_merge:} data that is merged into {config}" do
        schema = Inter.(intermediate, implementation([]), config_merge: {beer: "yes"})

        expect(schema[:config].to_h.inspect).must_equal %{{:wrap_static=>{}, :beer=>\"yes\"}}
      end

      it "{:config_merge} overrides values in {default_config}" do
        schema = Inter.(intermediate, implementation([]), config_merge: {beer: "yes", wrap_static: "yo"})

        expect(schema[:config].to_h.inspect).must_equal %{{:wrap_static=>"yo", :beer=>\"yes\"}}
      end
    end
  end
end
