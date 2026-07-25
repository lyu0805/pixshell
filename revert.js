const fs = require('fs');
const transcriptPath = '/Users/mrl/.gemini/antigravity/brain/42aed031-3742-414f-8ec3-014faea96393/.system_generated/logs/transcript_full.jsonl';
const logLines = fs.readFileSync(transcriptPath, 'utf8').split('\n').filter(Boolean);

let replaces = [];

for (const line of logLines) {
  try {
    const entry = JSON.parse(line);
    if (entry.tool_calls) {
      for (const call of entry.tool_calls) {
        if (call.name === 'replace_file_content' || call.name === 'multi_replace_file_content') {
          if (call.args && call.args.TargetFile) {
            replaces.push(call.args);
          } else if (call.arguments && call.arguments.TargetFile) {
            replaces.push(call.arguments);
          }
        }
      }
    }
  } catch (e) {}
}

replaces.reverse(); // Apply from newest to oldest

for (const args of replaces) {
  let file = args.TargetFile;
  if (!fs.existsSync(file)) {
    console.log("File not found: " + file);
    continue;
  }
  let content = fs.readFileSync(file, 'utf8');
  let originalContent = content;
  
  if (args.ReplacementChunks) {
    // For multi replace, we replace ReplacementContent back to TargetContent
    for (const chunk of [...args.ReplacementChunks].reverse()) {
       content = content.replace(chunk.ReplacementContent, chunk.TargetContent);
    }
  } else {
    // Single replace
    content = content.split(args.ReplacementContent).join(args.TargetContent);
  }
  
  if (content !== originalContent) {
    fs.writeFileSync(file, content, 'utf8');
    console.log("Reverted in " + file);
  } else {
    console.log("No match to revert in " + file);
  }
}
console.log("Done reverting.");
