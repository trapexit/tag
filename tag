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

ALLOWEDEXTS = ['.ogg','.flac']
IMPORTANTTAGS = ['date','album','albumartist','artist','title','tracknumber',
                 'remixer','discsubtitle','discnumber','originalartist',
                 'originalalbum','originaldate','totaltracks',
                 'totaldiscs','genre','media']
UNIQUETAGS = ['remixer','originalartist','originalalbum','originaldate',
              'tracknumber']

def main():
    opts, args = getopt.getopt(sys.argv[1:],
                               "hpdcqwgr:s:a:", 
                               ["help","print","dryrun",
                                "clear","query",'warn',
                                "guess","rename=","set=",
                                "alter=","move"])

    options = {'dryrun':False,'print':False,
               'clear':False,'query':False,
               'warn':False,'guess':False,
               'rename':False,'set':{},
               'alter':{},'move':False}
    for o,a in opts:
        if o in ("-d","--dryrun"):
            options['dryrun'] = True
        elif o in ('-p','--print'):
            options['print'] = True
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
            if options['set'].has_key(key):
                options['set'][key].append(value.decode("utf-8"))
            else:
                options['set'][key] = [value.decode("utf-8")]
        elif o in ('-a','--alter'):
            key,value = a.split('=')
            options['alter'][key.lower()] = value
        elif o in ("-h","--help"):
            usage()
            sys.exit(1)

    if len(args) == 0:
        args.append(os.getcwd())

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
            print "Renamed:",newpath
        if not args['dryrun']:
            try:
                os.makedirs(os.path.dirname(newpath))
            except:
                pass
            finally:
                if filepath != newpath:
                    if os.access(newpath,os.F_OK):
                        os.remove(newpath)
                    if args['move']:
                        shutil.move(filepath,newpath)
                    else:
                        shutil.copyfile(filepath,newpath)
                    filepath = newpath
        audio = mutagen.File(filepath)
        if audio:
            if args['clear']:
                audio.clear()
            settags(audio,tags)
            if args['print']:
                for key in audio:
                    values = audio[key]
                    for value in values:
                        print key.upper(),'=',value
                print "^================^"

            if args['dryrun'] == False:
                s = os.stat(filepath)
                os.chmod(filepath, s.st_mode | stat.S_IWUSR)
                audio.save()
                os.chmod(filepath, s.st_mode)
    return

def settags(audio,tags):
    if audio.has_key('source_format'):
        tags['sourceformat'] = audio['source_format']
    elif audio.has_key('sourceformat'):
        tags['sourceformat'] = audio['sourceformat']

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
        
def parsetagsfrompath(path):
    FILEPATH=os.path.abspath(path)
    FILENAME=os.path.basename(FILEPATH)
    PATH=os.path.dirname(FILEPATH)+'/';
    
    T = string.Template
    R = {}
    R['a0']  = "(?P<char>[^/])"
    R['a']   = "(?P<artist>[^/]+?)"
    R['aa']  = "(?P<albumartist>[^/]+?)"    
    R['oa']  = "(?P<originalartist>[^/]+?)"
    R['b']   = "(?P<album>[^/]+?)"
    R['ob']  = "(?P<originalalbum>[^/]+?)"
    R['t']   = "(?P<title>[^/]+?)"
    R['y']   = "(?P<date>\d\d\d\d)"
    R['oy']  = "(?P<originaldate>\d\d\d\d)"
    R['d']   = "(?P<discnumber>\d+)"
    R['c']   = "(?P<category>[^/]+?)"
    R['r']   = "(?P<release>[A-Z])"
    R['n']   = "(?P<tracknumber>\d+)"
    R['ds']  = "(?P<discsubtitle>[^/]+?)"
    R['e']   = "(?P<ext>\.[^\.]+?)"
    R['rm']  = "(?P<remixer>[^/]+?)"
    # Other tags? MEDIA,DISCTOTAL,TOTALDISCS,TRACKTOTAL,TOTALTRACKS,GENRE
    
    PATTERNS = [
        '/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/(Part|Side|Disc)_${d}_-_${ds}/',
        '/${a0}/${aa}/${c}/${y}${r}=${b}/(Part|Side|Disc)_${d}_-_${ds}/',
        '/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/${ds}/',
        '/${a0}/${aa}/${c}/${y}${r}=${b}/${ds}/',
        '/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/',
        '/${a0}/${aa}/${c}/${y}${r}=${b}/',
        '/${a0}/${aa}/${c}/${b}/']
    
    FILENAMEPATTERNS = [
        '${t}_\[${a}\]_\{${oa}\|${oy}\|${ob}\}${e}',
        '${t}_\[${a}\]_\{${oa}\|${oy}\}${e}',
        '${t}_\[${a}\]_\{${oa}\|${ob}\}${e}',
        '${t}_\[${a}\]_\{${oa}\}${e}',
        '${t}_\[${a}\]_\<${rm}\>${e}',        
        '${t}_\[${a}\]${e}',
        '${t}_\{${oa}\|${oy}\|${ob}\}${e}',
        '${t}_\{${oa}\|${oy}\}${e}',
        '${t}_\{${oa}\|${ob}\}${e}',
        '${t}_\{${oa}\}${e}',
        '${t}_\{${oa}\|${oy}|${ob}\}_\<${rm}\>${e}',
        '${t}_\{${oa}\|${oy}\}_\<${rm}\>${e}',
        '${t}_\{${oa}\|${ob}\}_\<${rm}\>${e}',
        '${t}_\{${oa}\}_\<${rm}\>${e}',
        '${t}_\<${rm}\>${e}',
        '${t}${e}']
    
    TAGS = {}
    for pattern in PATTERNS:
        reg = T(pattern).substitute(R)
        m = re.search(reg,PATH)
        if m:
            TAGS.update(m.groupdict())
            break

    additional = None
    for pattern in FILENAMEPATTERNS:
        reg = T('${n}='+pattern).substitute(R)
        m = re.match('^'+reg+'$',FILENAME)
        if m:
            additional = m.groupdict()
            break

    if not additional:
        for pattern in FILENAMEPATTERNS:
            reg = T(pattern).substitute(R)
            m = re.match('^'+reg+'$',FILENAME)
            if m:
                additional = m.groupdict()
                break

    TAGS.update(additional)        

    if TAGS:
        TAGS.setdefault('artist',TAGS.get('albumartist',''))
        
        if 'char' in TAGS: del TAGS['char']
        if 'release' in TAGS: del TAGS['release']
        if 'ext' in TAGS: del TAGS['ext']

        for key,value in TAGS.iteritems():
            TAGS[key] = [value.replace('_',' ')]

    return TAGS

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
            match = re.match("^(\d+)=.*$",file)
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
        match = re.match("(Part|Side|Disc)_(\d+).*",file)
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
    if not tags.has_key('tracknumber'):
        tn = re.search('(\d+)',filename)
        if tn:
            tags['tracknumber'] = [tn.group().decode('utf-8')]
    if not tags.has_key('totaltracks') and tags.has_key('tracknumber'):
        split = tags['tracknumber'][0].split('/')
        if len(split) == 2:
            tags['tracknumber'] = [split[0].decode('utf-8')]
            tags['totaltracks'] = [split[1].decode('utf-8')]
        else:
            tags['totaltracks'] = [unicode(totaltracks(filepath))]

    if not tags.has_key('totaldiscs') and tags.has_key('discnumber'):
        split = tags['discnumber'][0].split('/')
        if len(split) == 2:
            tags['discnumber'] = [split[0].decode('utf-8')]
            tags['totaldiscs'] = [split[1].decode('utf-8')]
        else:
            tags['totaldiscs'] = [unicode(totaldiscs(filepath))]

    if tags.has_key('albumartist') and not tags.has_key('artist'):
        tags['artist'] = tags['albumartist']
    elif not tags.has_key('albumartist') and tags.has_key('artist'):
        tags['albumartist'] = tags['artist']
            
    if not tags.has_key('artist') or not tags.has_key('album'):
        lcs = LongestCommonSubstring([os.path.splitext(file)[0] for file in files])
        if not lcs:
           lcs = os.path.basename(dirname)
        
        match = re.match('(.*)[ _]-[ _](.*)',lcs)
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
        rv = re.search(u'(.*?)(\d+)(.*)',filename)
        if rv and int(rv.group(2)) == int(tags['tracknumber'][0]):
            tags['title'] = [rv.group(3).strip()]
        else:
            tags['title'] = [filename.strip()]

    if not tags.has_key('category'):
        tags['category'] = [guesscategory(tags)]
            
    return tags;

def scrapetagsfrom(files):
    tags = {}
    for filepath in files:
        filename,ext = os.path.splitext(filepath)
        if not ext in ALLOWEDEXTS:
            continue
        audio = mutagen.File(filepath)
        if audio:
            for tag in IMPORTANTTAGS:
                if not tags.has_key(tag) and audio.has_key(tag):
                    tags[tag] = audio[tag]
    return tags

def createfilepathfromtags(base,tags,ext):
    KEYS = ['albumartist','album','title']
    for KEY in KEYS:
        if not tags.has_key(KEY):
            print "Error with renaming: necessary tag " + KEY.upper() + " not present"
            return None

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
        release = findnextrelease([base,char,albumartist,date])
        album = date+release+u"="+tags['album'][0]
    else:
        album = tags['album'][0]

    if tags.has_key('originaldate') and not tags.has_key('originalartist') and not tags.has_key('originalalbum'):
        album += u'_{'+tags['originaldate'][0]+u'}'

    if tags.has_key('discnumber'):
        if tags.has_key('totaltracks'):
            if int(tags['discnumber'][0]) != int(tags['totaldiscs'][0]):
                album += u'/Part_'+tags['discnumber'][0]
                if tags.has_key('discsubtitle'):
                    album += u'_-_'+tags['discsubtitle'][0]
        else:
            album += u'/Part_'+tags['discnumber'][0]
            if tags.has_key('discsubtitle'):
                album += u'_-_'+tags['discsubtitle'][0]            
        
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

    char.replace('/','\\')
    albumartist.replace('/','\\')
    category.replace('/','\\')
    album.replace('/','\\')
    title.replace('/','\\')
    
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

def findnextrelease(blah):
    return u"A"

def guesscategory(tags):
    album = tags.get('album',[''])[0].lower()
    if album.find('single') >= 0:
        return u'Single'
    elif album.find('ep') >= 0:
        return u'EP'
    elif album.find('demo') >= 0:
        return u'Demo'
    elif album.find('live') >= 0:
        return u'Live'
    elif album.find('remix') >= 0:
        return u'Remix'
    elif album.find('promo') >= 0:
        return u'Promo'
    else:
        return u'Album'

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
    print " -d | --dryrun            : process but don't commit"
    print " -p | --print             : print info"
    print " -c | --clear             : clear tags before writing new ones"
    print " -q | --query             : query discogs for additional info"
    print " -w | --warn              : warn of inconsistancies"
    print " -g | --guess             : guess tags not in expected path format"
    print " -r | --rename=<path>     : rename to standard path"
    print " -m | --move              : when renaming delete the original file"
    print " -s | --set=\"KEY=VALUE\"   : sets/overwrites tag"
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
