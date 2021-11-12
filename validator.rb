require "yaml"
require "json"
require "mustache"
require "json_schema"

class StackParser
    ONE_KB = 1024
    TEN_KB = ONE_KB * 10
    HUNDRED_KB = ONE_KB * 100
    DEFAULT_SCHEMA_VERSION = "0.1.0"
    SCHEMA_NONEXISTENT = "invalid schema version"
    VALIDATION_FAILED = "validation failed"
    STACK_TEMPLATE = "StackTemplate"
    STACK_TEMPLATE_VALUES = "StackTemplateValues"
  
    SCHEMAS = {
        "0.1.0" => JSON.parse(File.read("schemas/stack_schema-0.1.0.json"))
    }.freeze
    
    attr_reader :stack_schema, :stack_template, :stack_template_obj, :values

    def initialize(stack_template, values)
        @stack_template, @stack_template_obj = get_validated_stack_template(stack_template)
        @values = get_validated_values_yaml_obj(values)
    
        schema_version = @stack_template_obj.fetch("stack_schema_version", DEFAULT_SCHEMA_VERSION)
        raise StandardError.new("Initialization failed.", SCHEMA_NONEXISTENT) unless (@stack_schema = SCHEMAS[schema_version])
    end

    def get_stack_inputs
        @stack_template_obj["inputs"]
    end
    
    def get_stack_github_apps
        @stack_template_obj["github-apps"]
    end

    def sanitise_yaml_file(yaml_string)
        uncommented_string = String.new
        yaml_string.gsub(/\r\n?/, "\n")
        re = Regexp.new(/[#]/)
        yaml_string.each_line do |line|
          if index = (line =~ re)
            if index > 0
              uncommented_string.concat(line[0, index].rstrip, "\n")     # slice the string where the regular expression matches, and return it.
            end
          else
            uncommented_string.concat(line.rstrip, "\n")
          end
        end
        uncommented_string
    end

    def get_validated_values_yaml_obj(values)
        return nil if values.nil?
    
        # Check stack_template file size
        raise StandardError.new("Too big, should be smaller than 100KB.") if values.size > TEN_KB
        raise StandardError.new("#{STACK_TEMPLATE_VALUES}: #{VALIDATION_FAILED}") unless is_user_input_safe(values)
    
        begin
          values_obj = YAML.safe_load(values)
        rescue Psych::Exception
          raise StandardError.new("Invalid values YAML.")
        end
    
        values_obj
    end

    def is_user_input_safe(text)
        !text.kind_of?(String) || text.index(/{}/).nil?  # values yaml file shouldn't contain any mustache expression
    end

    def get_validated_stack_template(stack_template)
        raise StandardError.new("Empty file given.") if stack_template.nil?
        raise StandardError.new("Too big, should be smaller than 100KB.") if stack_template.size > HUNDRED_KB
    
        begin
          stack_template_obj = YAML.safe_load(stack_template)
        rescue Psych::Exception
          raise StandardError.new("Invalid YAML.")
        end
    
        return sanitise_yaml_file(stack_template), stack_template_obj
    end

    def self.validate_schema(stack_template_obj, schema, fail_fast = true)
        schema = JsonSchema.parse!(schema)
        schema.expand_references!
        schema.validate!(stack_template_obj, fail_fast: fail_fast)
    end
end

class StacksPrePublish
    WRONG_TYPE_ERROR = "Wrong type received"
    VALUES_MATCH_ERROR = "values.yml value doesn't match input type"
    INPUT_MULTIPLE_DECLARATION_ERROR = "Input has multiple declarations"
    VALID_VALUES_MATCH_ERROR = "Valid value type doesn't match input type"
    DEFAULT_VALUE_MATCH_ERROR = "Default value type doesn't match input type"
    UNDEFINED_INPUT_ERROR = "Undefined input referenced"
    INCONSISTENT_REFERENCE_ERROR = "Input referenced in multiple places with different types expected"
  
    def self.validate(stack_yaml, values_yaml = nil)
      new(stack_yaml, values_yaml).validate
    end
  
    def initialize(stack_yaml, values_yaml = nil)
      begin
        stack_parser = StackParser.new(stack_yaml, values_yaml)
      rescue StandardError => e
        raise StandardError.new(e.message)
      end
  
      @errors = []
  
      @inputs_defined = stack_parser.get_stack_inputs || []
      @values = (stack_parser.values || {}).fetch("inputs", {})
      @stack_template = stack_parser.stack_template
      @stack_schema = stack_parser.stack_schema
      @stack_template_obj = stack_parser.stack_template_obj
    end
  
    def validate
      # returns with set of inputs whose type couldn't be figured out
      inputs_without_value, inputs_set = inputs_without_values
  
      # if a set has been returned then there are inputs whose types need to be figured out from the configs
      populate_inputs_without_values(inputs_without_value, inputs_set) if @errors.empty? && inputs_without_value.kind_of?(Set)
  
      begin
        # validate with the stack schema after substituting the values
        StackParser.validate_schema(
          YAML.safe_load(StacksMustache.render(@stack_template, {"inputs" => @values})),
          @stack_schema,
          false
        ) if @errors.empty?
      rescue JsonSchema::AggregateError => schema_errors
        @errors.concat schema_errors.errors
      rescue JsonSchema::SchemaError => schema_error
        @errors.concat schema_errors.message
      end
  
      @errors
    end
  
    private
    def populate_inputs_without_values(inputs_without_value, inputs_set)
      input_references_with_type = {}
  
      # parses through the sections trying to find out input references and the type expected
      populate_input_references_with_type(@stack_template_obj, @stack_schema, input_references_with_type)
  
      input_references_with_type.each do |input_reference, type|
        # append error if input not defined in inputs section is referred
        @errors.append(StandardError.new("#{UNDEFINED_INPUT_ERROR} - #{input_reference}")) if !inputs_set.include? input_reference
  
        # assign default value based on type inferred from configs
        @values[input_reference] = default_value_for_type(type) if inputs_without_value.include? input_reference
      end
    end
  
    def inputs_without_values
      # validate if inputs are defined as per schema
      begin
        StackParser.validate_schema(@inputs_defined, schema_for(@stack_schema, ["inputs"]), false)
      rescue JsonSchema::AggregateError => schema_errors
        @errors.concat schema_errors.errors
      rescue JsonSchema::SchemaError => schema_error
        @errors.concat schema_errors.message
      end
  
      return @errors unless @errors.empty?
  
      inputs_set = Set.new
      inputs_without_value = Set.new
  
      @inputs_defined.each do |input|
        value = nil
  
        if inputs_set.include? input["name"]
          @errors.append(StandardError.new("#{INPUT_MULTIPLE_DECLARATION_ERROR} - #{input["name"]}"))
        else
          inputs_set << input["name"]
        end
  
        # assign value default based on type
        value = default_value_for_type(input["type"]) if input.key? "type"
  
        if input.key? "validvalues"
          # ensure all validvalues provided are of the defined type
          if (type = input.fetch("type", nil)).present?
            input["validvalues"].each do |valid_value|
              @errors.append(StandardError.new("#{VALID_VALUES_MATCH_ERROR}: valid_value => #{valid_value}, received_type => #{type_map(valid_value.class)}, expected_type => #{type}")) if type_map(valid_value.class) != type
            end
          end
  
          # assign the first validvalue
          value = input["validvalues"].first
        end
  
        if input.key? "default"
          # ensure default value is of the defined type
          @errors.append(StandardError.new("#{DEFAULT_VALUE_MATCH_ERROR}: received_type => #{type_map(input["default"].class)}, expected_type => #{type}}")) if (type = input.fetch("type", nil)).present? && type_map(input["default"].class) != type
  
          # assign default value
          value = input["default"]
        end
  
        if @values.key? input["name"]
          # ensure values.yml value is of the defined type
          @errors.append(StandardError.new("#{VALUES_MATCH_ERROR}: received_type => #{type_map(@values[input["name"]].class)}, expected_type => #{type}}")) if (type = input.fetch("type", nil)).present? && type_map(@values[input["name"]].class) != type
  
          # assign values.yml value
          value = @values[input["name"]]
        end
  
        # input value couldn't be inferred
        if value.nil?
          inputs_without_value << input["name"]
        else
          @values[input["name"]] = value
        end
      end
  
      [inputs_without_value, inputs_set]
    end
  
    def populate_input_references_with_type(config, schema, input_references_with_type)
      # get the expected type or assume object by default
      expected_type = schema.fetch("type", "object")
  
      if expected_type == "object"
        # don't dig down deeper if current object doesn't meet expected type
        unless config.class == Hash
          @errors.append(StandardError.new("#{WRONG_TYPE_ERROR}: received_type => #{type_map(config.class)}, expected_type => #{expected_type}"))
          return
        end
  
        # dig down further for each key value
        config.each do |key, value|
          populate_input_references_with_type(value, schema_for(schema, [key]), input_references_with_type)
        end
      elsif expected_type == "array"
        # don't dig down deeper if current object doesn't meet expected type
        unless config.class == Array
          @errors.append(StandardError.new("#{WRONG_TYPE_ERROR}: received_type => #{type_map(config.class)}, expected_type => #{expected_type}"))
          return
        end
  
        # dig down element wise based on schema
        item_schema = schema_from_ref(schema["items"])
        config.each do |c|
          populate_input_references_with_type(c, item_schema, input_references_with_type)
        end
  
      # care only if it is an input reference, else handled by schema validation
      elsif config.class == String && config.strip.start_with?("${{") && config.end_with?("}}")
        input_name = config[3..-3].strip.split(".")
        if input_name.length == 2 && input_name[0] == "inputs"
          # already seen a reference to input but with different type expected
          if input_references_with_type.key?(input_name[1]) && input_references_with_type[input_name[1]] != schema["type"]
            @errors.append(StandardError.new("#{INCONSISTENT_REFERENCE_ERROR}: input => #{input_name[1]}, types => [#{schema["type"]}, #{input_references_with_type[input_name[1]]}]"))
            return
          end
  
          # assign type of input based on schema
          input_references_with_type[input_name[1]] = schema["type"]
        end
      end
    end
  
    def default_value_for_type(type)
      DEFAULT_VALUE_MAP.fetch type, nil
    end
  
    def type_map(type)
      TYPE_MAP.fetch type, "invalid"
    end
  
    # get the children schema based on path
    def schema_for(parent_schema, path)
      return parent_schema if path.empty?
      raise StandardError.new("Invalid stack.yml, undefined key.") if parent_schema.nil?
  
      # handling if current schema is for an array
      current_schema = if parent_schema.key?("type") && parent_schema["type"] == "array"
        parent_schema["items"]
      else
        parent_schema
      end
  
      # populating current schema from ref
      current_schema = schema_from_ref(current_schema)
  
      # getting the next level schema
      current_schema = current_schema["properties"][path.shift]
      schema_for(schema_from_ref(current_schema), path)
    end
  
    # get schema from ref
    def schema_from_ref(parent_schema)
      if parent_schema.nil?
        raise StandardError.new("Invalid stack.yml, undefined key.")
      elsif parent_schema.key?("$ref")
        definition_path = parent_schema["$ref"].split("/")
  
        raise StandardError.new("Invalid stack schema, not your fault.") if definition_path.shift != "#"
  
        parent_schema = @stack_schema
        definition_path.each do |key|
          parent_schema = parent_schema[key]
        end
      end
  
      parent_schema
    end
  
    TYPE_MAP = {
      Integer => "integer",
      String => "string",
      TrueClass => "boolean",
      FalseClass => "boolean",
      Float => "integer",
      Array => "array"
    }.freeze
  
    DEFAULT_VALUE_MAP = {
      "integer" => 0,
      "string" => "sample_string",
      "boolean" => false
    }.freeze
end

class StacksMustache < Mustache
    class StacksMustacheTemplate < Mustache::Template
        def tokens(src = @source)
            parser = Mustache::Parser.new(@options)
            parser.otag = "${{"
            parser.compile(src)
        end
    end

    def context
        super
    end

    def self.templateify(obj, options = {})
        template = obj.is_a?(StacksMustacheTemplate) ? obj : StacksMustacheTemplate.new(obj, options)
    end

    def self.render(expression, replacement_context = {})
        # change from default mustache tag to ${{ }} just when using this function
        new.render(expression, replacement_context)
    end

    def render(expression, replacement_context = {}, raise_on_context_miss = true)
        self.raise_on_context_miss = raise_on_context_miss
        super(expression, replacement_context)
    end
end

def validate
  template = File.open(ARGV[0]).read

  if template == ""
    File.write("pre_publish_validate.errors.log", "Empty template given.")
    return
  end

  values = ""
  values = File.open(ARGV[1]) if ARGV[1] 

  error_file = ""
  begin
    StacksPrePublish.validate(template, values).each do |error|
        error_file = "#{error.message}\n#{error_file}"
    end
  rescue StandardError => e
    File.write("pre_publish_validate.errors.log", e.message)
    return
  end
  File.write("pre_publish_validate.errors.log", error_file)
  puts "sup"
  puts Dir.entries(".")

end


validate