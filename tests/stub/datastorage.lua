local base = os.getenv("MEALIE_TEST_DIR") or "/tmp/mealie-kotest"
local D = {}
-- Mimics a Kindle: koreader.sh only chdirs into the install directory and
-- never sets KO_HOME, so the plain data dir is a relative ".".
function D:getDataDir() return "." end
function D:getSettingsDir() return "./settings" end
function D:getFullDataDir() return base .. "/koreader" end
return D
