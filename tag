#!/usr/bin/python
# http://musicbrainz.org/doc/MusicBrainz_Picard/Tags/Mapping

import mutagen
import string
import os
import stat
import sys
import re
import getopt
import difflib
import shutil

try:
    import discogs_client as discogs
except ImportError:
    pass

DEBUG = False
ALLOWEDEXTS = ['.ogg','.flac']
IMPORTANTTAGS = ['date','album','albumartist','artist','title','tracknumber',
                 'remixer','discsubtitle','discnumber','originalartist',
                 'originalalbum','originaldate','totaltracks',
                 'totaldiscs','genre','media']
UNIQUETAGS = ['remixer','originalartist','originalalbum','originaldate',
              'tracknumber','title']
REGEXES = {
    'a0' : u"(?P<char>[^/])",
    'a'  : u"(?P<artist>[^/]+?)",
    'aa' : u"(?P<albumartist>[^/]+?)",
    'oa' : u"(?P<originalartist>[^/]+?)",
    'b'  : u"(?P<album>[^/]+?)",
    'ob' : u"(?P<originalalbum>[^/]+?)",
    't'  : u"(?P<title>[^/]+?)",
    'y'  : u"(?P<date>\d\d\d\d)",
    'oy' : u"(?P<originaldate>\d\d\d\d)",
    'd'  : u"(?P<discnumber>\d+)",
    'c'  : u"(?P<category>[^/]+?)",
    'r'  : u"(?P<release>[A-Z])",
    'n'  : u"(?P<tracknumber>\d+)",
    'ds' : u"(?P<discsubtitle>[^/]+?)",
    'e'  : u"(?P<ext>\.[^\.]+?)",
    'rm' : u"(?P<remixer>[^/]+?)"
    }

def main():
    opts, args = getopt.getopt(sys.argv[1:],
                               "hpecqwgr:s:u:a:", 
                               ["help","print","exec",
                                "clear","query",'warn',
                                "guess","rename=","set=",
                                "unset=","alter=","move","debug"])

    options = {'exec':False,'print':False,
               'clear':False,'query':False,
               'warn':False,'guess':False,
               'rename':False,'set':{},
               'unset':[],'alter':{},'move':False,
               'debug':False}
    for o,a in opts:
        if o in ("-e","--exec"):
            options['exec'] = True
        elif o in ('-p','--print'):
            options['print'] = True
        elif o in ('--debug'):
            global DEBUG
            options['debug'] = True
            DEBUG=True
        elif o in ('-c','--clear'):
            options['clear'] = True
        elif o in ('-q','--query'):
            options['query'] = True
        elif o in ('-w','--warn'):
            options['warn'] = True
        elif o in ('-g','--guess'):
            options['guess'] = True
        elif o in ('-m','--move'):
            options['move'] = True
        elif o in ('-r','--rename'):
            if not os.path.exists(a) or not os.path.isdir(a):
                print "\nError: rename base path "+a+" doesn't exist\n"
                usage()
                sys.exit(1)
            options['rename'] = a.decode("utf-8")
        elif o in ('-s','--set'):
            key,value = a.split('=')
            key = key.lower()
            if options['set'].has_key(key):
                options['set'][key].append(value.decode("utf-8"))
            else:
                options['set'][key] = [value.decode("utf-8")]
        elif o in ('-u','--unset'):
            options['unset'].extend(a.split(','))
        elif o in ('-a','--alter'):
            key,value = a.split('=',1)
            options['alter'][key.lower()] = value
        elif o in ("-h","--help"):
            usage()
            sys.exit(1)

    if len(args) == 0:
        args.append(os.getcwdu())

    for path in args:
        path = os.path.abspath(path)
        if os.path.isfile(path):
            tagfile(options,path)
        elif os.path.isdir(path):
            for root, dirs, files in os.walk(path):
                files.sort()
                for file in files:
                    tagfile(options,os.path.join(root,file))
        
    return 

def tagfile(args,filepath):
    dirname  = os.path.dirname(filepath)
    filename,ext = os.path.splitext(filepath)
    if not ext in ALLOWEDEXTS:
        return

    if args['guess']:
        tags = guesstags(filepath)
    else:
        tags = parsetagsfrompath(filepath)
        if tags:
            tags.update(totals(filepath))

    if not tags:
        print "ERROR: unable to derrive tags for " + filepath
        return

    if args['query']:
        dtags = discogtags(tags)
        if args['warn']:
            printwarnings(tags,dtags)
        tags.update(dtags)
    tags.update(args['set'])
    tags.update(padnumerictags(tags))
    tags.update(altertags(args['alter'],tags))
    for value in args['unset']:
        if tags.has_key(value):
            del tags[value]
    if args['print']:
        print "v================v"
        print filepath
    if args['rename']:
        newpath = createfilepathfromtags(args['rename'],tags,ext)
        if not newpath:
            return
        tags = parsetagsfrompath(newpath)
        if tags:
            tags.update(totals(filepath))
        tags.update(padnumerictags(tags))                    
        checkfilepathfromtags(newpath,tags)
        if args['print']:
            if args['move']:
                word = "Move"
            else:
                word = "Copy"
            print word+ " to: " + newpath
        if args['exec']:
            try:
                dirname = os.path.dirname(newpath)
                if not os.path.exists(dirname):
                    os.makedirs(dirname)
                if filepath != newpath:
                    if os.access(newpath,os.F_OK):
                        os.remove(newpath)
                    if args['move']:
                        shutil.move(filepath,newpath)
                    else:
                        shutil.copyfile(filepath,newpath)
                    filepath = newpath
            except Exception as e:
                if not os.path.exists(newpath):
                    print "Error creating path: " + os.path.dirname(newpath)
                else:
                    print "Error:",e
                return
    try:
        audio = mutagen.File(filepath)
        if audio != None:
            if args['clear']:
                cleartags(audio)
            settags(audio,tags)
            if args['print']:
                for key in audio:
                    values = audio[key]
                    for value in values:
                        print key.upper(),'=',value
                print "^================^"

            if args['exec']:
                s = os.stat(filepath)
                os.chmod(filepath, s.st_mode | stat.S_IWUSR)
                audio.save()
                os.chmod(filepath, s.st_mode)
    except Exception as e:
        print "Error:",e,filepath
        
    return

def cleartags(audio):
    sf = None
    if audio.has_key('source_format'):
        sf = audio['source_format']
    elif audio.has_key('sourceformat'):
        sf = audio['sourceformat']

    audio.clear()
    if sf:
        audio['sourceformat'] = sf

def settags(audio,tags):
    if audio.has_key('source_format'):
        tags['sourceformat'] = audio['source_format']
    elif audio.has_key('sourceformat'):
        tags['sourceformat'] = audio['sourceformat']

    for tag in ['char','release','ext']:
        if tags.has_key(tag):
            del tags[tag]
        
    for key,value in tags.iteritems():
        audio[key] = value

def padnumerictags(tags):
    if tags.has_key('tracknumber'):
        if tags.has_key('totaltracks'):
            tags['tracknumber'] = [padnumber(tags['tracknumber'][0],
                                             tags['totaltracks'][0])]
        else:
            tags['tracknumber'] = [padnumber(tags['tracknumber'][0])]
    if tags.has_key('totaltracks'):
        tags['totaltracks'] = [padnumber(tags['totaltracks'][0])]
    if tags.has_key('discnumber'):
        if tags.has_key('totaldiscs'):
            tags['discnumber'] = [padnumber(tags['discnumber'][0],
                                            tags['totaldiscs'][0])]
        else:
            tags['discnumber'] = [padnumber(tags['discnumber'][0])]
    if tags.has_key('totaldiscs'):
        tags['totaldiscs'] = [padnumber(tags['totaldiscs'][0])]

    return tags

def parsetagsfromdirpath(path):
    FILEPATH=os.path.abspath(path)
    if os.path.isfile(FILEPATH):
        PATH=os.path.dirname(FILEPATH)+os.sep;
    elif os.path.isdir(FILEPATH):
        PATH+=os.sep
    elif not os.path.splitext(FILEPATH)[1]:
        PATH=FILEPATH
    elif os.path.splitext(FILEPATH)[1]:
        PATH=os.path.dirname(FILEPATH)+os.sep

    T = string.Template
    
    PATTERNS = [
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/(Part|Side|Disc)_${d}_-_${ds}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/(Part|Side|Disc)_${d}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}/(Part|Side|Disc)_${d}_-_${ds}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}/(Part|Side|Disc)_${d}/',        
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/${ds}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}/${ds}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}/',
        u'/${a0}/${aa}/${c}/${b}/']
    
    TAGS = {}
    for pattern in PATTERNS:
        reg = T(pattern).substitute(REGEXES)
        m = re.search(reg,PATH,re.UNICODE)
        if m:
            TAGS.update(m.groupdict())
            break

    if TAGS:
        for key,value in TAGS.iteritems():
            if not isinstance(value,unicode):
                value = value.decode("utf-8")
            TAGS[key] = [value.replace('_',' ')]

    return TAGS

def parsetagsfromfilename(filename):
    global DEBUG
    FILEPATH=os.path.abspath(filename)
    FILENAME=os.path.basename(FILEPATH)
    
    T = string.Template
    
    FILENAMEPATTERNS = [
        u'${t}_\[${a}\]_\{${oa}\|${oy}\|${ob}\}${e}',
        u'${t}_\[${a}\]_\{${oa}\|${oy}\}${e}',
        u'${t}_\[${a}\]_\{${oa}\|${ob}\}${e}',
        u'${t}_\[${a}\]_\{${oa}\}${e}',
        u'${t}_\[${a}\]_\<${rm}\>${e}',        
        u'${t}_\[${a}\]${e}',
        u'${t}_\{${oa}\|${oy}\|${ob}\}${e}',
        u'${t}_\{${oa}\|${oy}\}${e}',
        u'${t}_\{${oa}\|${ob}\}${e}',
        u'${t}_\{${oy}\}${e}',
        u'${t}_\{${oa}\}${e}',
        u'${t}_\{${oa}\|${oy}\|${ob}\}_\<${rm}\>${e}',
        u'${t}_\{${oa}\|${oy}\}_\<${rm}\>${e}',
        u'${t}_\{${oa}\|${ob}\}_\<${rm}\>${e}',
        u'${t}_\{${oy}\}_\<${rm}\>${e}',
        u'${t}_\{${oa}\}_\<${rm}\>${e}',
        u'${t}_\<${rm}\>${e}',
        u'${t}${e}']
    
    TAGS = {}
    for pattern in FILENAMEPATTERNS:
        reg = T(u'${n}='+pattern).substitute(REGEXES)
        m = re.match(u'^'+reg+u'$',FILENAME,re.UNICODE)
        if m:
            if DEBUG:
                print "Pattern matched:",pattern
            TAGS = m.groupdict()
            break

    if not TAGS:
        for pattern in FILENAMEPATTERNS:
            reg = T(pattern).substitute(REGEXES)
            m = re.match(u'^'+reg+u'$',FILENAME,re.UNICODE)
            if m:
                if DEBUG:
                    print "Pattern matched:",pattern
                TAGS = m.groupdict()
                break

    if TAGS:
        if 'ext' in TAGS: del TAGS['ext']

        for key,value in TAGS.iteritems():
            if not isinstance(value,unicode):
                value = value.decode("utf-8")
            TAGS[key] = [value.replace('_',' ')]

    return TAGS

def parsetagsfrompath(filepath):
    dirtags  = parsetagsfromdirpath(filepath)
    filetags = parsetagsfromfilename(filepath) 

    if not filetags.has_key('artist'):
        filetags['artist'] = dirtags['albumartist']

    tags = dirtags;
    tags.update(filetags)
        
    return tags

def totals(filepath):
    tags = {}
    tags['totaltracks'] = [unicode(totaltracks(filepath))]
    count = totaldiscs(filepath)
    if count:
        tags['totaldiscs'] = [unicode(totaldiscs(filepath))]
    return tags

def totaltracks(filepath):
    dirname = os.path.dirname(filepath)
    files = os.listdir(dirname)
    max = 0
    count = 0
    for file in files:
        filename,ext = os.path.splitext(file)
        if ext in ALLOWEDEXTS:
            count += 1
            match = re.match("^(\d+)=.*$",file,re.UNICODE)
            if match:
                match = int(match.groups()[0])
                if match > max:
                    max = match
    if max:
        return max
    return count

def totaldiscs(filepath):
    dirname = os.path.dirname(filepath)
    dirname = os.path.dirname(dirname)
    files = os.listdir(dirname)
    max = 0
    for file in files:
        match = re.match("(Part|Side|Disc)_(\d+).*",file,re.UNICODE)
        if match:
            match = int(match.groups()[1])
            if match > max:
                max = match
    return max

def padnumber(num, max = None):
    if max == None or int(num) < 100:
        rv = u"%(tn)02d" % {"tn":int(num)}
    elif int(max) > 100:
        rv = u"%(tn)03d" % {"tn":int(num)}
    else:
        rv = u"%(tn)d" % {"tn":int(num)}        
    return rv

discogscache = {}
def finddiscogrelease(tags):
    discogs.user_agent = "tagger/0.0 +http://google.com"
    
    if not tags.has_key('artist') and not tags.has_key('album') and not tags.has_key('albumartist'):
        return None

    if tags.has_key('albumartist'):
        artist = tags['albumartist'][0].lower()
    elif tags.has_key('artist'):
        artist = tags['artist'][0].lower()
    else:
        artist = ''
        
    if tags.has_key('album'):
        album = tags['album'][0].lower()
    else:
        album = ''

    releases = discogscache.get(artist)
    if not releases:
        for query in [artist+' '+album,artist,album]:
            try:
                search = discogs.Search(query)
                releases = search.results()
                discogscache[artist] = releases
                continue
            except:
                pass

    possible = []
    for release in releases:
        if isinstance(release,discogs.MasterRelease):
            release = release.key_release
        if isinstance(release,discogs.Release):
            if tags.has_key('totaltracks'):
                if int(tags['totaltracks'][0]) != numofdiscogtracks(release.tracklist):
                    continue
            if tags.has_key('date') and release.data.has_key('year'):
                if (int(release.data['year']) > int(tags['date'][0])+1 or
                    int(release.data['year']) < int(tags['date'][0])-1):
                    continue
            if tags.has_key('tracknumber') and tags.has_key('title'):
                for track in release.tracklist:
                    try:
                        if int(track['position']) == int(tags['tracknumber'][0]):
                            ratio = difflib.SequenceMatcher(None,tags['title'][0],track['title']).ratio()
                            if ratio > 0.50:
                                possible.append(release)
                                break
                    except:
                        pass
            else:
                possible.append(release)

    MAX=(None,0)
    for release in possible:
        ratio = difflib.SequenceMatcher(None,album,release.title.lower()).ratio()
        if ratio > MAX[0]:
            MAX = (release,ratio)
    return MAX[0]

def numofdiscogtracks(LIST):
    count = 0
    for x in LIST:
        if x['type'] == 'Track':
            count += 1
    return count

def discogtags(tags):
    dtags = {}
    release = finddiscogrelease(tags)
    if release:
        if release.data.has_key('year'):
            dtags['date'] = [unicode(release.data['year'])]
        if release.data.has_key('genres'):
            dtags['genre'] = release.data['genres']
        if release.data.has_key('styles'):
            dtags['genre'].extend(release.data['styles'])
        if release.data.has_key('notes'):
            dtags['comment'] = [release.data['notes']]
        if len(release.labels) and release.labels[0].data.has_key('name'):
            dtags['label'] = [release.labels[0].data['name'].decode('utf-8')]

    return dtags

def guesstags(filepath):
    tags = {}    

    filepath = os.path.abspath(filepath)
    dirname = os.path.dirname(filepath)    
    filename = os.path.basename(filepath)
    filename,ext = os.path.splitext(filename)

    files = os.listdir(dirname)
    files.remove(filename+ext)    

    tags = scrapetagsfrom([os.path.join(dirname,file) for file in files])
    for tag in UNIQUETAGS:
        if tag in tags:
            del tags[tag]
    tags.update(scrapetagsfrom([filepath]))

    pathtags = parsetagsfromdirpath(filepath)
    tags.update(pathtags)

    if not tags.has_key('tracknumber'):
        tn = re.search('(\d+)',filename,re.UNICODE)
        if tn:
            tags['tracknumber'] = [unicode(tn.group())]
    if tags.has_key('tracknumber'):
        split = tags['tracknumber'][0].split('/')
        if len(split) == 2:
            tags['tracknumber'] = [unicode(split[0])]
            if not tags.has_key('totaltracks'):
                tags['totaltracks'] = [unicode(split[1])]
        else:
            tags['totaltracks'] = [unicode(totaltracks(filepath))]
        if not tags['tracknumber'][0].isdigit():
            tags['tracknumber'] = [unicode(guesstracknumber(filepath))]

    if not tags.has_key('totaldiscs') and tags.has_key('discnumber'):
        split = tags['discnumber'][0].split('/')
        if len(split) == 2:
            tags['discnumber'] = [unicode(split[0])]
            tags['totaldiscs'] = [unicode(split[1])]
        else:
            tags['totaldiscs'] = [unicode(totaldiscs(filepath))]

    if tags.has_key('totaldiscs') and int(tags['totaldiscs'][0]) == 1:
        del tags['totaldiscs']
        del tags['discnumber']

    if tags.has_key('albumartist') and not tags.has_key('artist'):
        tags['artist'] = tags['albumartist']
    elif not tags.has_key('albumartist') and tags.has_key('artist'):
        tags['albumartist'] = tags['artist']
            
    if not tags.has_key('artist') or not tags.has_key('album'):
        lcs = LongestCommonSubstring([os.path.splitext(file)[0] for file in files])
        if not lcs:
           lcs = os.path.basename(dirname)
        
        match = re.match('(.*)[ _]-[ _](.*)',lcs,re.UNICODE)
        if match:
            if not tags.has_key('artist'):
                tags['artist'] = [match.group(1).strip()]
            if not tags.has_key('album'):
                tags['album'] = [match.group(2).strip()]
        else:
            if not tags.has_key('artist'):
                tags['artist'] = [lcs.strip()]
            elif not tags.has_key('album'):
                tags['album'] = [lcs.strip()]

    if not tags.has_key('title'):
        rv = re.search(u'(.*?)(\d+)(.*)',filename,re.UNICODE)
        if rv and int(rv.group(2)) == int(tags['tracknumber'][0]):
            tags['title'] = [rv.group(3).strip()]
        else:
            tags['title'] = [unicode(filename.strip())]
#        lcs = LongestCommonSubstring(tags['title'][0],tags['albumartist'][0])
#        tags['title'][0] = tags['title'][0].replace(lcs,'').strip(' _-')
        tags['title'][0] = tags['title'][0].strip(' _-')
    tags['title'][0] = tags['title'][0].strip()

    if not tags.has_key('category'):
        tags['category'] = [guesscategory(tags)]

    if tags.has_key('date'):
        rv = re.search('(\d\d\d\d)',tags['date'][0])
        if rv:
            tags['date'] = [rv.group(0).strip()]
            
    return tags;

def scrapetagsfrom(files):
    tags = {}
    for filepath in files:
        filename,ext = os.path.splitext(filepath)
        if not ext in ALLOWEDEXTS:
            continue
        try:
            audio = mutagen.File(filepath)
            if not audio:
                continue
            for tag in IMPORTANTTAGS:
                if not tags.has_key(tag) and audio.has_key(tag):
                    tags[tag] = audio[tag]
        except:
            pass
    return tags

def createfilepathfromtags(base,tags,ext):
    KEYS = ['albumartist','album','title']
    for KEY in KEYS:
        if not tags.has_key(KEY):
            print "Error with renaming: necessary tag " + KEY.upper() + " not present"
            return None

    subtitle = ''
    albumartist = tags['albumartist'][0]
    split = albumartist.split()
    if split[0].lower() in ['a','the']:
        char = split[1][0]
    else:
        char = split[0][0]
    
    if tags.has_key('category'):
        category = tags['category'][0]
    else:
        category = guesscategory(tags)

    if tags.has_key('date'):
        date = tags['date'][0]
        if tags.has_key('release'):
            release = tags['release'][0]
        else:
            path = os.path.join(base,char,albumartist,category)
            release = findnextrelease(path,tags['date'][0],tags['album'][0])
        album = date+release+u"="+tags['album'][0]
    else:
        album = tags['album'][0]

    if tags.has_key('originaldate') and not tags.has_key('originalartist') and not tags.has_key('originalalbum'):
        album += u'_{'+tags['originaldate'][0]+u'}'

    if tags.has_key('discnumber'):
        subtitle = u'Disc_'+tags['discnumber'][0]
        if tags.has_key('discsubtitle'):
            subtitle += u'_-_'+tags['discsubtitle'][0]

    if tags.has_key('tracknumber'):
        title = tags['tracknumber'][0].split('/')[0]+u"="+tags['title'][0]
    else:
        title = tags['title'][0]

    if tags.has_key('artist') and albumartist != tags['artist'][0]:
        title += u'_['+tags['artist'][0]+']'
        
    if tags.has_key('originalartist'):
        title += u"_{"+tags['originalartist'][0]
        if tags.has_key('originaldate'):
            title += u"|"+tags['originaldate'][0]
        if tags.has_key('originalalbum'):
            title += u"|"+tags['originalalbum'][0]
        title += u"}"
    if tags.has_key('remixer'):
        title += u"_<"+tags['remixer'][0]+u">"
    title += ext

    subtitle    = re.sub(r'[_ ]*/[_ ]*',r'_-_',subtitle)
    albumartist = re.sub(r'[_ ]*/[_ ]*',r'_-_',albumartist)
    artist      = re.sub(r'[_ ]*/[_ ]*',r'_-_',artist)    
    category    = re.sub(r'[_ ]*/[_ ]*',r'_-_',category)
    album       = re.sub(r'[_ ]*/[_ ]*',r'_-_',album)
    title       = re.sub(r'[_ ]*/[_ ]*',r'_-_',title)

    if subtitle != '':
        path = os.path.join(base,char,albumartist,category,album,subtitle,title)
    else:
        path = os.path.join(base,char,albumartist,category,album,title)

    path = string.replace(path,' ','_')

    return path

def checkfilepathfromtags(filepath,tags):
    newtags = parsetagsfrompath(filepath)
    for tag in newtags:
        if not tags.has_key(tag):
            print newtags, "\n", tags
            sys.exit(0)
        elif newtags[tag] != tags[tag]:
            print filepath
            print newtags,"\n", tags
            sys.exit(0)

def findnextrelease(path,year,album):
    return 'A'
    if os.path.exists(path) and os.path.isdir(path):
        pattern  = u'^'+year+u'([A-Z])'
        pattern2 = pattern+'='+album.replace(' ','_')
        rv = 'A'
        files = os.listdir(path)
        for file in files:
            match = re.match(pattern2,file,re.UNICODE)
            if match:
                return match.groups()[0]
            match = re.match(pattern,file,re.UNICODE)
            if match:
                match = match.groups()[0]
                if match > rv:
                    rv = match
        return unichr(ord(rv)+1)
    else:
        return 'A'

def guesscategory(tags):
    album = tags.get('album',[''])[0].lower()
    if re.search('[\s(]*single[)\s]*',album):
        return u'Single'
    elif re.search('[\s(]*ep[)\s]*',album):
        return u'EP'
    elif re.search('[\s(]*demo[)\s]*',album):
        return u'Demo'
    elif re.search('[\s(]*live[)\s]*',album):
        return u'Live'
    elif re.search('[\s(]*remix[)\s]*',album):
        return u'Remix'
    elif re.search('[\s(]*promo[)\s]*',album):
        return u'Promo'
    else:
        return u'Album'

def guesstracknumber(filepath):
    dirname = os.path.dirname(filepath)
    basename = os.path.basename(filepath)
    filename,ext = os.path.splitext(basename)
    files = os.listdir(dirname)
    files.sort()
    count = 0
    for file in files:
        tmpfilename,tmpext = os.path.splitext(file)
        if tmpext == ext:
            count += 1
            if tmpfilename == filename:
                break
    return count

# "album=t|u|l|r:old:new "
def altertags(alters,tags):
    newtags = {}
    for key in alters:
        if tags.has_key(key):
            newtags[key] = []
            for tagvalue in tags[key]:
                ops = alters[key].split('|')
                for op in ops:
                    if op == 't':
                        tagvalue = tagvalue.title()
                    elif op == 'c':
                        tagvalue = tagvalue.capitalize()
                    elif op == 'l':
                        tagvalue = tagvalue.lower()
                    elif op == 'u':
                        tagvalue = tagvalue.upper()
                    elif op == 's':
                        tagvalue = tagvalue.swapcase()
                    elif op[0] == 'r':
                        split = op.split(':')
                        if len(split) == 3:
                            tagvalue = tagvalue.replace(split[1],split[2])
                newtags[key].append(tagvalue)
    return newtags

def LongestCommonSubstring(S1, S2 = None):
    if type(S1) == type([]) and S2 == None:
        lcs = S1[0]
        for element in S1:
            lcs = LongestCommonSubstring(element,lcs)
        return lcs
    
    M = [[0]*(1+len(S2)) for i in xrange(1+len(S1))]
    longest, x_longest = 0, 0
    for x in xrange(1,1+len(S1)):
        for y in xrange(1,1+len(S2)):
            if S1[x-1] == S2[y-1]:
                M[x][y] = M[x-1][y-1] + 1
                if M[x][y]>longest:
                    longest = M[x][y]
                    x_longest  = x
            else:
                M[x][y] = 0
    return S1[x_longest-longest: x_longest]

def printwarnings(tags,dtags):
    if tags.has_key('date') and dtags.has_key('date'):
        if tags['date'] != dtags['date']:
            print "WARNING: discogs indicates the release year " + dtags['date'] + " vs. " + tags['date']

def usage():
    print "usage: %(name)s [opts] [filepath] ..." % {'name':sys.argv[0]}
    print
    print " -h | --help              : print help"
    print " -e | --exec              : process but don't commit"
    print " -p | --print             : print info"
    print " -c | --clear             : clear tags before writing new ones"
    print " -q | --query             : query discogs for additional info"
    print " -w | --warn              : warn of inconsistancies"
    print " -g | --guess             : guess tags not in expected path format"
    print " -r | --rename=<path>     : rename to standard path"
    print " -m | --move              : when renaming delete the original file"
    print " -s | --set=\"KEY=VALUE\"   : sets/overwrites tag"
    print " -u | --unset=""          : unset tags"
    print " -a | --alter=\"KEY=<mod>\" : alter tags"
    print "  <mod> = \"t|c|l|u|s|r:old:new\""
    print "  t = title capitalization"
    print "  c = capitalize first letter"
    print "  l = lowercase"
    print "  u = uppercase"
    print "  s = swapcase"
    print "  r = replace:oldvalue:newvalue"
    print

if __name__ == "__main__":
    main()
