const fs = require('fs');
const allContents = fs.readFileSync('Readme.txt', 'utf-8');
let curfn = '';
let args = new Array();
let indesc = false;
let curdesc = '';
let contents = '{\n';
let cherry = false;
let collecting = false;
let isflag = false

allContents.split(/\r?\n/).forEach((line) => {
  if (line === 'MIDIUtils.SetOnError(fn)') {
    collecting = true;
  }
  if (!collecting) return;

  let m = line.match(/^MIDIUtils\.(.*?)\((.*?)\)/)
  if (m) {
    curfn = m[1];
    args = [];
    isflag = false;

    let filtarg = m[2].replaceAll(/{.*?}/g, '');
    filtarg = filtarg.replaceAll(/\s*?=.*?(,)?/g, '$1')
    filtarg.split(', ').forEach((argument) => {
      let rawarg = argument.match(/([\w\.]+)/)
      if (rawarg) {
        args.push(rawarg[1].trim());
      }
    });
  }
  else if (m = line.match(/^MIDIUtils\.([^\(\s]*?)\s*?=\s*?(true|false)/)) {
    isflag = true;
    curfn = m[1];
    args = [];
  }
  else if (curfn != '' && !indesc) {
    let regx = new RegExp(curfn + ':\s*(.*?)$');
    let m2 = line.match(regx);
    if (m2) {
      curdesc = m2[1].trim();
      indesc = true;
    }
    else if (isflag && line.match(/\-\-\[\[/)) {
      curdesc = '';
      indesc = true;
    }
  }
  else {
    if (indesc) {
      if (line.match(/Arguments:|Return Value:|--]]/)) {
        curdesc += '\\n\\n';
        curdesc = curdesc.replaceAll('"', '\'');
        let outstr = '';
        outstr = '\t"' + curfn + ' lua": {\n\t\t"prefix": "mu.' + curfn + '",\n\t\t"body": "mu.' + curfn;
        let argstr = isflag ? '' : '(';
        for (i in args) {
          if (parseInt(i) > 0) { argstr += ', '; }
          argstr += '${' + (parseInt(i)+1) + ':' + args[i] + '}';
        }
        if (!isflag) argstr += ')';
        argstr += '$0';
        outstr += argstr;
        outstr += '",\n\t\t"description": "' + curdesc + '"\n\t}';
        if (cherry) {
          contents += ',\n';
        }
        cherry = true
        contents += outstr;
        curfn = '';
        indesc = false;
        // console.log(outstr);
      }
      else {
        if (curdesc != '') curdesc += ' ';
        curdesc += line.trim();
      }
    }
  }

});

contents += '\n}\n';
contents = contents.replaceAll(/\s*?(\\n\\n)/g, '$1');
fs.writeFile('/Users/jeremydb/Desktop/ReaScript-MIDIUtils.code-snippets', contents, err => {

});
