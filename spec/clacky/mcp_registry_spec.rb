# frozen_string_literal: true

require "tmpdir"
require "json"
require "fileutils"

RSpec.describe Clacky::Mcp::Registry do
  let(:fake_server_path) { File.expand_path("../../support/fake_mcp_server.rb", __FILE__) }
  let(:home) { Dir.mktmpdir }
  let(:work) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(home, ".clacky"))
    stub_const("ENV", ENV.to_hash.merge("HOME" => home))
    allow(Dir).to receive(:home).and_return(home)
  end

  after do
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(work)
  end

  def write_global_config(servers)
    File.write(File.join(home, ".clacky", "mcp.json"), JSON.dump("mcpServers" => servers))
  end

  def fake_config(description: "Fake echo+add server.")
    {
      "fake" => {
        "command" => "ruby",
        "args" => [fake_server_path],
        "description" => description,
      },
    }
  end

  describe "config loading" do
    it "treats missing mcp.json as empty" do
      reg = described_class.new(working_dir: work)
      expect(reg.any?).to eq(false)
      expect(reg.virtual_skills).to eq([])
    end

    it "loads servers from ~/.clacky/mcp.json" do
      write_global_config(fake_config)
      reg = described_class.new(working_dir: work)
      expect(reg.any?).to eq(true)
      expect(reg.configured?("fake")).to eq(true)
    end

    it "ignores servers with missing command" do
      write_global_config("broken" => { "args" => ["x"] })
      reg = described_class.new(working_dir: work)
      expect(reg.configured?("broken")).to eq(false)
    end
  end

  describe "#virtual_skills" do
    before { write_global_config(fake_config(description: "Hello.")) }

    it "creates a fork-mode VirtualSkill per server" do
      reg = described_class.new(working_dir: work)
      skills = reg.virtual_skills
      expect(skills.size).to eq(1)
      sk = skills.first
      expect(sk).to be_a(Clacky::Mcp::VirtualSkill)
      expect(sk.identifier).to eq("mcp:fake")
      expect(sk.slash_command).to eq("/mcp:fake")
      expect(sk.fork_agent?).to eq(true)
      expect(sk.user_invocable?).to eq(true)
      expect(sk.description).to eq("Hello.")
    end

    it "uses a default description when none provided" do
      write_global_config("fake" => { "command" => "ruby", "args" => [fake_server_path] })
      reg = described_class.new(working_dir: work)
      sk = reg.virtual_skills.first
      expect(sk.description).to include("MCP server")
    end
  end

  describe "live JSON-RPC against fake server" do
    before { write_global_config(fake_config) }

    it "routes calls through call_tool" do
      reg = described_class.new(working_dir: work, idle_timeout: 0)
      begin
        result = reg.call_tool("fake", "echo", { "message" => "hi" })
        expect(result).to be_a(Hash)
        expect(result.dig("content", 0, "text")).to eq("echo: hi")

        result = reg.call_tool("fake", "add", { "a" => 2, "b" => 3 })
        expect(result.dig("content", 0, "text").to_f).to eq(5.0)
      ensure
        reg.shutdown
      end
    end

    it "fills VirtualSkill content with each tool's inputSchema" do
      reg = described_class.new(working_dir: work, idle_timeout: 0)
      begin
        sk = reg.virtual_skill_for("fake")
        content = sk.process_content
        expect(content).to include("# MCP Server: fake")
        expect(content).to include("### `echo`")
        expect(content).to include("### `add`")
        expect(content).to include("\"required\"")
      ensure
        reg.shutdown
      end
    end
  end

  describe "Tools::McpCall" do
    before { write_global_config(fake_config) }

    it "dispatches via the agent's mcp_registry" do
      reg = described_class.new(working_dir: work, idle_timeout: 0)
      begin
        agent = Object.new
        agent.define_singleton_method(:mcp_registry) { reg }
        tool = Clacky::Tools::McpCall.new

        result = tool.execute(server: "fake", tool: "echo",
                              arguments: { message: "world" }, agent: agent)
        expect(result).to eq("echo: world")
      ensure
        reg.shutdown
      end
    end

    it "returns a clear error when server is not configured" do
      reg = described_class.new(working_dir: work, idle_timeout: 0)
      agent = Object.new
      agent.define_singleton_method(:mcp_registry) { reg }
      tool = Clacky::Tools::McpCall.new

      result = tool.execute(server: "missing", tool: "x", arguments: {}, agent: agent)
      expect(result).to be_a(Hash)
      expect(result[:error]).to match(/not configured/i)
    end
  end
end
