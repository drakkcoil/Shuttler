#!/usr/bin/env ruby

require 'xcodeproj'

project_path = 'Shuttler.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'Shuttler' }
if target.nil?
  puts "Error: Could not find 'Shuttler' target."
  exit 1
end

puts "Target: #{target.name}"
puts "Resources Build Phase Files:"
target.resources_build_phase.files.each do |f|
  puts " - #{f.display_name} (Ref: #{f.file_ref&.path})"
end

# Check if we can find Assets.xcassets anywhere
existing_ref = project.files.find { |f| f.path =~ /Assets.xcassets/ }
if existing_ref
  puts "Found existing file reference: #{existing_ref.path}"
else
  puts "No existing file reference for Assets.xcassets found."
  
  # Try to add it to the ROOT group (project.main_group) directly if Shuttler group is synchronized
  # The path should be relative to project root.
  # Project root contains Shuttler folder, which contains Assets.xcassets.
  # So path is "Shuttler/Assets.xcassets"
  
  puts "Attempting to create file reference in main group..."
  # We use the main_group (project root) which is usually a PBXGroup
  file_ref = project.main_group.new_file('Shuttler/Assets.xcassets')
  
  puts "Created file ref: #{file_ref.path}"
  
  # Add to build phase
  target.resources_build_phase.add_file_reference(file_ref)
  puts "Added to resources build phase."
  
  project.save
  puts "Project saved."
end
