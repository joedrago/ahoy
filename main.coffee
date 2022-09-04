fs = require 'fs'
rimraf = require 'rimraf'
path = require 'path'
puppeteer = require 'puppeteer'
StreamZip = require 'node-stream-zip'
dircompare = require 'dir-compare'


pad = (s, fill = '0', count = 2) ->
  s = String(s)
  while s.length < count
    s = String(fill) + s
  return s

generateNowString = ->
  d = new Date()
  return "#{d.getFullYear()}#{pad(d.getMonth()+1)}#{pad(d.getDate())}-#{pad(d.getHours())}#{pad(d.getMinutes())}#{pad(d.getSeconds())}"

backupTimestamp = generateNowString()

makeFreshDownloadDir = (dir) ->
  if (fs.existsSync(dir))
    rimraf.sync(dir)
  fs.mkdirSync(dir, { recursive: true })

waitMS = (time) ->
 return new Promise (resolve, reject) ->
   setTimeout(resolve, time)

dirExists = (dir) ->
  if not fs.existsSync(dir)
    return false
  if not fs.lstatSync(dir).isDirectory()
    return false
  return true

findLatestFileLinks = (modName) ->
  lowerModName = modName.toLowerCase()
  browser = await puppeteer.launch({ headless: true })
  page = await browser.newPage()
  await page.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.181 Safari/537.36");
  await page.goto("https://www.curseforge.com/wow/addons/#{lowerModName}")

  sidebarTitles = await page.$$eval '.e-sidebar-subheader > a', (elements) ->
    return elements.map (e) ->
      e.innerHTML
  sidebarLinks = await page.$$eval '.cf-recentfiles > li > div > a.overflow-tip', (elements) ->
    return elements.map (e) ->
      { href: e.href, name: e.dataset.name }
  await browser.close()

  if sidebarTitles.length != sidebarLinks.length
    console.error "findLatestFileLinks() is probably messed up. Please debug with mod name \"#{modName}\"."
    return null

  results = []
  for title, titleIndex in sidebarTitles
    link = sidebarLinks[titleIndex]
    results.push {
      version: title
      filename: link.name
      href: link.href
    }
  return results

waitForFile = (downloadDir, timeout) ->
  return new Promise (resolve, reject) ->
    intervalTime = 1000
    remainingTime = timeout
    interval = setInterval(->
      downloadedFilenames = fs.readdirSync(downloadDir)
      # console.log "checking files: ", downloadedFilenames
      if downloadedFilenames.length > 0 and not downloadedFilenames[0].match(/crdownload/)
        clearInterval(interval)
        resolve(true)
        return
      remainingTime -= intervalTime
      if remainingTime < 0
        clearInterval(interval)
        resolve(false)
        return
    , intervalTime)

# returns null on success, or error string on failure
# WARNING: tempOutputPath does not have to exist yet, but will be nuked! don't be an idiot!
# Upon success "#{tempOutputPath}/extracted" will have stuff in it
downloadLatestZip = (modName, versionFilter, tempOutputPath) ->
  console.log "Finding latest download for #{modName} (#{versionFilter})..."
  files = await findLatestFileLinks(modName)
  if not files?
    return "[#{modName}] Failed to find latest file links"
  latestFile = null
  for file in files
    if file.version.indexOf(versionFilter) != -1
      latestFile = file
      break
  if not latestFile?
    return "[#{modName}] Failed to find matching version (#{versionFilter}) out of #{files.length} choices"

  lowerModName = modName.toLowerCase()

  browser = await puppeteer.launch({ headless: true })
  page = await browser.newPage()
  await page.setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.181 Safari/537.36");
  await page.goto("https://example.com")

  downloadDir = path.resolve(tempOutputPath)
  # console.log "temp download path: #{downloadDir}"
  makeFreshDownloadDir(downloadDir)
  client = await page.target().createCDPSession()
  await client.send('Page.setDownloadBehavior', {
      behavior: 'allow',
      downloadPath: downloadDir
  });

  matches = latestFile.href.match(/\/files\/(\d+)/)
  if not matches?
    return "[#{modName}] Couldn't make sense of download link: #{latestFile.href}"
  fileId = parseInt(matches[1])
  if not fileId? or (fileId < 1)
    return "[#{modName}] Download link has no ID in it: #{latestFile.href}"

  downloadUrl = "https://www.curseforge.com/wow/addons/#{lowerModName}/download/#{fileId}"
  console.log "Downloading [#{latestFile.filename}]: #{downloadUrl}"
  await page.goto(downloadUrl)

  # manually click on the "here" link to skip the 5 second wait
  await page.$$eval 'a', (elements) ->
    for e in elements
      if e.innerHTML == "here"
        e.click()
        return

  downloadSuccess = await waitForFile(downloadDir, 15000)
  await browser.close()

  # console.log "downloadSuccess: #{downloadSuccess}"

  downloadedFilenames = fs.readdirSync(downloadDir)
  if downloadedFilenames.length != 1
    return "[#{modName}] Failed to find a downloaded file from: #{downloadUrl}"

  downloadedFilename = path.resolve(downloadDir, downloadedFilenames[0])
  extractDir = path.resolve(downloadDir, "extracted")
  fs.mkdirSync(extractDir, { recursive: true })
  zip = new StreamZip.async({ file: downloadedFilename })
  count = await zip.extract(null, extractDir)
  # console.log("Extracted #{count} entries.")
  await zip.close()
  return null

updateMod = (modName, versionFilter, wowAddonsDir, wowAddonsBackupDir, configFileDir) ->
  tmpDir = path.resolve(configFileDir, "tmp.ahoy.download.#{modName}")
  err = await downloadLatestZip(modName, versionFilter, tmpDir)
  if err?
    console.error "Failed to download latest zip: #{err}"
    return

  extractedDir = path.resolve(tmpDir, "extracted")
  dirs = fs.readdirSync(extractedDir)
  updatedAtLeastOne = false
  for dir in dirs
    srcPath = path.resolve(extractedDir, dir)
    if not fs.lstatSync(srcPath).isDirectory()
      continue

    needsMove = true
    dstPath = path.resolve(wowAddonsDir, dir)
    if fs.existsSync(dstPath)
      if not fs.lstatSync(dstPath).isDirectory()
        console.error "ERROR: dstPath isn't a directory: #{dstPath}"
        continue

      # console.log "Diffing: #{dir}"
      # console.log "Diffing:\n * #{srcPath}\n * #{dstPath}"
      result = dircompare.compareSync(srcPath, dstPath, { compareContent: true })
      if result.same
        # console.log "Up to date."
        needsMove = false
      else
        backupPath = path.resolve(wowAddonsBackupDir, "#{dir}.#{backupTimestamp}")
        console.log "Backup: #{backupPath}"
        fs.renameSync(dstPath, backupPath)

    if needsMove
      console.log "Create: #{dir}"
      # console.log "Updating:\n *  #{srcPath}\n => #{dstPath}"
      fs.renameSync(srcPath, dstPath)
      updatedAtLeastOne = true

  if not updatedAtLeastOne
    console.log "Already up to date."

  if (fs.existsSync(tmpDir))
    rimraf.sync(tmpDir)

main = ->
  syntax = ->
    console.log "Syntax: ahoy [-h]"
    console.log "        ahoy [-v] [-m] [configFile|dirWithAhoyJSON]"
    console.log ""
    console.log "Options:"
    console.log "        -h,--help         This help output"
    console.log "        -v,--verbose      Verbose output"
    console.log "        -m,--missing      Only update missing mods (default: update all listed mods)"
    console.log ""
    console.log "If a directory is supplied, ahoy will look in that directory for a file named ahoy.json."
    console.log "If no path is supplied, ahoy will look in the current directory for a file named ahoy.json."
    process.exit(1)

  args = require('minimist')(process.argv.slice(2), {
    boolean: ['h', 'v', 'm']
    alias:
      help: 'h'
      verbose: 'v'
      missing: 'm'
  })
  if args.help
    syntax()

  rawConfigFilename = "ahoy.json"
  if args._.length > 0
    rawConfigFilename = args._.shift()

  configFilename = path.resolve(rawConfigFilename)
  if dirExists(configFilename)
    configFilename = path.resolve(configFilename, "ahoy.json")
  if not fs.existsSync(configFilename)
    console.error("ERROR: No config file found: #{configFilename}")
    return

  configFileDir = path.dirname(fs.realpathSync(configFilename))

  console.log "Config: #{configFilename}"

  configs = JSON.parse(fs.readFileSync(configFilename, "utf8"))
  for config in configs
    if not config.addonsDir? or not config.backupDir? or not config.version? or not config.mods?
      console.error("ERROR: Config requires: addonsDir, backupDir, version, mods")
      return

    config.addonsDir = path.resolve(configFileDir, config.addonsDir)
    if not dirExists(config.addonsDir)
      console.error("ERROR: addonsDir doesn't exist: #{addonsDir}")
      return

    config.backupDir = path.resolve(configFileDir, config.backupDir)
    if not dirExists(config.backupDir)
      console.log "Creating backup dir: #{config.backupDir}"
      fs.mkdirSync(config.backupDir, { recursive: true })

    if config.mods.length < 1
      console.error("ERROR: No mods listed.")
      return

  for config, configIndex in configs
    console.log "\n------------------------------------------------------------------------------"
    console.log "** Config #{configIndex+1} of #{configs.length} **\n"
    console.log "Version  : #{config.version}"
    console.log "AddonsDir: #{config.addonsDir}"
    console.log "BackupDir: #{config.backupDir}"

    console.log("\nUpdating #{config.mods.length} mods...")

    modCount = config.mods.length
    for mod, modIndex in config.mods
      dstPath = path.resolve(config.addonsDir, mod)
      if args.missing and dirExists(dstPath)
        console.log "\n[#{modIndex+1}/#{modCount}] Skipping #{mod}..."
        continue
      console.log "\n[#{modIndex+1}/#{modCount}] Updating #{mod}..."
      await updateMod(mod, config.version, config.addonsDir, config.backupDir, configFileDir)


  console.log "\n------------------------------------------------------------------------------"
  console.log "\nAll configs complete!"

module.exports = main
