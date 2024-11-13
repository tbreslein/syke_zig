if config.symlinks ~= nil then
  if type(config.symlinks) == "table" then
    for k, v in ipairs(config.symlinks) do
      if v.source == nil then
        error("missing required field: config.symlinks.source")
      end
      if v.target == nil then
        error("missing required field: config.symlinks.target")
      end
      -- if v.force == nil then
      --   v.force = false
      -- end
    end
  end
end

return config
