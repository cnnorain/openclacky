# Three-way Merge Module

Provides complete three-way merge functionality for software version updates, configuration merging, and other scenarios.

## Features

### Core Features
- **Three-way Merge Algorithm**: Intelligent merge based on base/ours/theirs
- **Difference Calculation**: Line-level and character-level difference calculation with caching
- **Conflict Resolution**: Multiple strategies (keep local, use new version, intelligent merge, mark conflict)
- **Configuration File Merge**: JSON/YAML structured merge with array append, merge-by-ID strategies

### Enhanced Features
- **Security Protection**: Path traversal detection, symbolic link check, file size limit
- **Binary File Detection**: Based on extension and byte analysis
- **Rename Detection**: Based on content similarity algorithm
- **Incremental Backup**: Only backup changed files
- **Atomic Write**: Use temporary file + rename for atomicity
- **Recursion Depth Limit**: Prevent stack overflow

## Installation

```ruby
require "clacky/three_way_merge"
```

## Basic Usage

### Merge Single File

```ruby
merger = Clacky::ThreeWayMerge.create_merger
result = merger.merge_file("config.json", base_content, ours_content, theirs_content)

if result.success?
  puts "Merge successful: #{result.content}"
elsif result.has_conflicts?
  puts "Conflicts exist: #{result.conflicts}"
end
```

### Merge Multiple Files

```ruby
files = {
  "config.json" => { base: base1, ours: ours1, theirs: theirs1 },
  "settings.yaml" => { base: base2, ours: ours2, theirs: theirs2 }
}

results = Clacky::ThreeWayMerge.merge_files(files)
report = merger.generate_report(results)
puts report
```

### Merge Directories

```ruby
result = Clacky::ThreeWayMerge.merge_directories(
  base_dir, ours_dir, theirs_dir, output_dir
)

puts "Total files: #{result[:stats][:total]}"
puts "Auto-merged: #{result[:stats][:auto_merged]}"
puts "Conflicts: #{result[:stats][:conflicts]}"
```

### Merge with Rollback Protection

```ruby
result = Clacky::ThreeWayMerge.merge_with_rollback(files)

unless result[:success]
  puts "Merge failed: #{result[:error]}"
  puts "Auto-rollback to backup: #{result[:backup_id]}"
end
```

## Version Management

```ruby
vm = Clacky::ThreeWayMerge.version_manager

# Save version snapshots
vm.save_snapshot("1.0.0", "/path/to/v1")
vm.save_snapshot("1.1.0", "/path/to/v2")

# Get version content
v1_content = vm.get_snapshot("1.0.0")
```

## Conflict Resolution

```ruby
# Check for conflicts
has_conflict = Clacky::ThreeWayMerge.has_conflicts?(content)

# Resolve conflicts (keep local version)
resolved = Clacky::ThreeWayMerge.resolve_to_ours(content)

# Resolve conflicts (keep new version)
resolved = Clacky::ThreeWayMerge.resolve_to_theirs(content)
```

## Rename Detection

```ruby
old_files = { "old/path.rb" => "content" }
new_files = { "new/path.rb" => "content" }

renames = Clacky::ThreeWayMerge.detect_renames(old_files, new_files, threshold: 0.8)
# => [{ old: "old/path.rb", new: "new/path.rb", similarity: 1.0 }]
```

## Configuration Options

### Merger Options

```ruby
merger = Clacky::ThreeWayMerge.create_merger(
  enhanced: true,                    # Use enhanced version (default)
  default_strategy: :mark,           # Default conflict strategy
  auto_resolve_same_change: true,    # Auto-merge same changes
  ignore_patterns: ["*.log", "tmp/*"] # Ignored file patterns
)
```

### Config Merger Options

```ruby
config_merger = Clacky::ThreeWayMerge::EnhancedConfigMerger.new(
  format: :json,                # File format :json or :yaml
  array_strategy: :append,      # Array strategy :append, :replace, :merge_by_id
  type_coerce: true             # Type coercion
)
```

## Security Features

### Path Validation

```ruby
Clacky::ThreeWayMerge::Security.validate_path!("config/settings.rb")  # => true
Clacky::ThreeWayMerge::Security.validate_path!("../../etc/passwd")     # => SecurityError
Clacky::ThreeWayMerge::Security.validate_path!("./././etc/passwd")     # => SecurityError
```

### File Size Limit

```ruby
# Default 10MB limit
Clacky::ThreeWayMerge::Security.safe_content_size?(content)  # => true/false
```

### Symbolic Link Check

```ruby
Clacky::ThreeWayMerge::Security.symlink?(path)  # => true/false
Clacky::ThreeWayMerge::Security.safe_read(path)  # => content or nil
```

## Error Handling

```ruby
begin
  result = Clacky::ThreeWayMerge.merge_file(file_path, base, ours, theirs)
rescue SecurityError => e
  puts "Security error: #{e.message}"
rescue ArgumentError => e
  puts "Argument error: #{e.message}"
rescue => e
  puts "Merge error: #{e.message}"
end
```

## File Structure

```
lib/clacky/
├── three_way_merge.rb                    # Main entry module
└── three_way_merge/
    ├── security.rb                       # Security utility module
    ├── diff_engine.rb                    # Difference calculation engine
    ├── enhanced_diff_engine.rb           # Enhanced difference engine
    ├── file_classifier.rb                # File classifier
    ├── conflict_resolver.rb              # Conflict resolver
    ├── config_merger.rb                  # Configuration file merger
    ├── enhanced_config_merger.rb         # Enhanced configuration merger
    ├── three_way_merger.rb               # Three-way merge core
    ├── version_manager.rb                # Version manager
    ├── rollback_manager.rb               # Rollback manager
    └── enhanced_rollback_manager.rb      # Enhanced rollback manager
```

## Convenience Alias

```ruby
# TWM is an alias for Clacky::ThreeWayMerge
TWM.merge_file(file_path, base, ours, theirs)
TWM.version_manager
TWM.rollback_manager
```

## Version History

### v2.0.0
- Merged all enhanced features into main module
- Added security protection (path validation, symbolic link check)
- Added binary file detection
- Added rename detection
- Improved intelligent merge algorithm
- Added recursion depth limit
- Improved rollback mechanism (incremental backup, atomic write)

### v1.0.0
- Initial version
- Basic three-way merge functionality
- Configuration file merge
- Version management
