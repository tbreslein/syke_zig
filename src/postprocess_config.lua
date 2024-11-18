if config.symlinks ~= nil then
  if type(config.symlinks) == "table" then
    for k, v in ipairs(config.symlinks) do
      if v.absent == nil then
        v.absent = false
      end
      if v.source == nil and v.absent == false then
        error("missing required field: config.symlinks.source")
      end
      if v.target == nil then
        error("missing required field: config.symlinks.target")
      end
      if v.force == nil then
        v.force = true
      end
    end
  end
end

return config
