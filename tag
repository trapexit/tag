#!/usr/bin/python
# -*- coding: utf-8 -*-
# http://musicbrainz.org/doc/MusicBrainz_Picard/Tags/Mapping

import mutagen
import string
import math
import os
import stat
import sys
import re
import getopt
import difflib
import shutil

DEBUG = False
ALLOWEDEXTS = ['.ogg','.flac']
IMPORTANTTAGS = ['date','album','albumartist','artist','title',
                 'tracknumber','remixer','discsubtitle',
                 'discnumber','originalartist','originalalbum',
                 'originaldate','totaltracks','totaldiscs']
UNIQUETAGS = ['remixer','originalartist','originalalbum',
              'originaldate','tracknumber','title']
REGEXES = {
    'a0' : u'(?P<char>[^/])',
    'a'  : u'(?P<artist>[^/]+?)',
    'aa' : u'(?P<albumartist>[^/]+?)',
    'oa' : u'(?P<originalartist>[^/]+?)',
    'b'  : u'(?P<album>[^/]+?)',
    'ob' : u'(?P<originalalbum>[^/]+?)',
    't'  : u'(?P<title>[^/]+?)',
    'y'  : u'(?P<date>\d\d\d\d)',
    'oy' : u'(?P<originaldate>\d\d\d\d)',
    'd'  : u'(?P<discnumber>\d+)',
    'c'  : u'(?P<category>[^/]+?)',
    'r'  : u'(?P<release>[A-Z])',
    'n'  : u'(?P<tracknumber>\d+)',
    'ds' : u'(?P<discsubtitle>[^/]+?)',
    'e'  : u'(?P<ext>\.[^\.]+?)',
    'rm' : u'(?P<remixer>[^/]+?)'
    }

def main():
    try:
        if(len(sys.argv) == 1):
            usage()
            sys.exit(1)
        else:
            options,args = process_options(sys.argv[1:])
    except Exception as e:
        print("Error: ",e)
        usage()
        sys.exit(1)

    if len(args) == 0:
        args.append(os.getcwdu())

    for path in args:
        path = os.path.abspath(path)
        if os.path.isfile(path):
            tagfile(options,path)
        elif os.path.isdir(path):
            fsenc = sys.getfilesystemencoding()
            for root, dirs, files in os.walk(path.encode(fsenc)):
                files.sort()
                for file in files:
                    tagfile(options,os.path.join(root,file))
        
    return 

def process_options(args):
    opts, args = getopt.getopt(sys.argv[1:],
                               "hpecgr:s:u:a:", 
                               ["help","print","exec",
                                "clear","guess",
                                'copy=','set=',
                                'unset=','alter=',
                                'delete','debug'])
    
    options = {'exec':False,'print':False,
               'clear':False,'guess':False,
               'copy':False,'debug':False,
               'delete':False,
               'set':{},'unset':[],'alter':{}}
    
    for opt,arg in opts:
        if opt in ('-e','--exec'):
            options['exec'] = True
        elif opt in ('-p','--print'):
            options['print'] = True
        elif opt in ('--debug'):
            global DEBUG
            options['debug'] = True
            DEBUG = True
        elif opt in ('-c','--clear'):
            options['clear'] = True
        elif opt in ('-g','--guess'):
            options['guess'] = True
        elif opt in ('-d','--delete'):
            options['delete'] = True
        elif opt in ('--copy'):
            if not os.path.exists(arg) or not os.path.isdir(arg):
                print '\nError: copy base path '+arg+' doesn\'t exist\n'
                usage()
                sys.exit(1)
            options['copy'] = arg.decode('utf-8')
        elif opt in ('-s','--set'):
            key,value = arg.split('=')
            key = key.lower()
            if options['set'].has_key(key):
                options['set'][key].append(value.decode('utf-8'))
            else:
                options['set'][key] = [value.decode('utf-8')]
        elif opt in ('-u','--unset'):
            options['unset'].extend(arg.split(','))
        elif opt in ('-a','--alter'):
            key,value = arg.split('=',1)
            options['alter'][key.lower()] = value
        elif opt in ('-h','--help'):
            usage()
            sys.exit(1)

    return options,args

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

    sanitize_tags(tags)
            
    if not tags:
        print 'ERROR: unable to derrive tags for ' + filepath
        return

    tags.update(args['set'])
    tags.update(padnumerictags(tags))
    tags.update(altertags(args['alter'],tags))
    for value in args['unset']:
        if tags.has_key(value):
            del tags[value]
    if args['print']:
        print "v================v"
        print filepath
    if args['copy']:
        newpath = createfilepathfromtags(args['copy'],tags,ext)
        if not newpath:
            return

        if tags:
            tags.update(totals(filepath))
        tags.update(padnumerictags(tags))                    
        if args['print']:
            if args['delete']:
                word = u'Move'
            else:
                word = u'Copy'
            print word + u' to: ' + newpath
        if args['exec']:
            try:
                dirname = os.path.dirname(newpath)
                if not os.path.exists(dirname):
                    os.makedirs(dirname)
                if filepath != newpath:
                    if os.access(newpath,os.F_OK):
                        os.remove(newpath)
                    if args['delete']:
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
                add_images(audio,filepath)
                audio.save()
                os.chmod(filepath, s.st_mode)
    except Exception as e:
        print "Error:",e,filepath
        
    return

def add_images(audio,filepath):
    if type(audio) != mutagen.flac.FLAC:
        return

    dirname = os.path.dirname(filepath)
    files = os.listdir(dirname)
    for file in files:
        filename,ext = os.path.splitext(file)
        if ext in ['.png','.jpeg','.jpg']:
            image = mutagen.flac.Picture()
            fullpath = os.path.join(dirname,file)
            with open(fullpath,'rb') as f:
                image.data = f.read()
            audio.add_picture(image)

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
            tags['tracknumber'] = [padnumber(tags['tracknumber'][0],tags['totaltracks'][0],2)]
        else:
            tags['tracknumber'] = [padnumber(tags['tracknumber'][0],minpadding=2)]

    if tags.has_key('totaltracks'):
        tags['totaltracks'] = [padnumber(tags['totaltracks'][0],minpadding=2)]

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
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\[${ds}\]_\{${oy}\}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\{${oy}\}/',
        u'/${a0}/${aa}/${c}/${y}${r}=${b}_\[${ds}\]/',        
        u'/${a0}/${aa}/${c}/${y}${r}=${b}/',
        u'/${a0}/${aa}/${c}/${b}_\[${ds}\]_\{${oy}\}/',
        u'/${a0}/${aa}/${c}/${b}_\{${oy}\}/',
        u'/${a0}/${aa}/${c}/${b}_\[${ds}\]/',        
        u'/${a0}/${aa}/${c}/${b}/']
    
    TAGS = {}
    for pattern in PATTERNS:
        reg = T(pattern).substitute(REGEXES)
        m = regex_search(reg,PATH)
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
    FILEPATH = os.path.abspath(filename)
    FILENAME = os.path.basename(FILEPATH)
    
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
        reg = T(u'${d}.${n}='+pattern).substitute(REGEXES)
        m = regex_match(u'^'+reg+u'$',FILENAME)
        if m:
            if DEBUG:
                print "Pattern matched:",pattern
            TAGS = m.groupdict()
            break
            
    for pattern in FILENAMEPATTERNS:
        reg = T(u'${n}='+pattern).substitute(REGEXES)
        m = regex_match(u'^'+reg+u'$',FILENAME)
        if m:
            if DEBUG:
                print "Pattern matched:",pattern
            TAGS = m.groupdict()
            break

    if not TAGS:
        for pattern in FILENAMEPATTERNS:
            reg = T(pattern).substitute(REGEXES)
            m = regex_match(u'^'+reg+u'$',FILENAME)
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

    if not filetags.has_key('artist') and dirtags.has_key('albumartist'):
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
            match = regex_match("^(\d+)=.*$",file)
            if match:
                match = int(match.groups()[0])
                if match > max:
                    max = match
    if max:
        return max
    return count

def totaldiscs(filepath):
    dirname = os.path.dirname(filepath)
    files = os.listdir(dirname)
    max = 0
    for file in files:
        match = regex_search("(^|\D+)(\d)\d\d\D+",file)
        if match:
            match = int(match.groups()[1])
            if match > max:
                max = match
    return max

def padnumber(num, maxnum = 100, minpadding = None):
    if int(maxnum) <= 0:
        maxnum = 1
    padding = math.log(float(maxnum),10)
    if padding < minpadding:
        padding = minpadding

    return unicode(int(num)).zfill(int(padding))

def guess_tracknumber_totaltracks(tags,filepath):
    filepath     = os.path.abspath(filepath)
    dirname      = os.path.dirname(filepath)
    filename     = os.path.basename(filepath)
    filename,ext = os.path.splitext(filename)

    if not tags.has_key('tracknumber'):
        tracknumber = regex_search('(\d+)',filename)
        if tracknumber:
            tags['tracknumber'] = [unicode(tn.group())]

    if tags.has_key('tracknumber'):
        split = tags['tracknumber'][0].split('/')
        if len(split) == 2:
            tags['tracknumber'] = [unicode(split[0])]
            if not tags.has_key('totaltracks'):
                tags['totaltracks'] = [unicode(split[1])]
            else:
                totaltracks = totaltracks(filepath)
                tags['totaltracks'] = [unicode(totaltracks)]

    if (tags.has_key('tracknumber') and not
        tags['tracknumber'][0].isdigit()):
        files = os.listdir(dirname)
        files.sort()
        totaltracks = 0
        tracknumber = 0
        for file in files:
            tmpfilename,tmpext = os.path.splitext(file)
            if tmpext == ext:
                totaltracks += 1
                if tmpfilename == filename:
                    tracknumber = totaltracks
        tags['tracknumber'] = [unicode(tracknumber)]
        tags['totaltracks'] = [unicode(totaltracks)]
            
def guess_discnumber_totaldiscs(tags,filepath):
    if (not tags.has_key('totaldiscs') and
        tags.has_key('discnumber')):
        split = tags['discnumber'][0].split('/')
        if len(split) == 2:
            tags['discnumber'] = [unicode(split[0])]
            tags['totaldiscs'] = [unicode(split[1])]
        else:
            tags['totaldiscs'] = [unicode(totaldiscs(filepath))]

    if not tags.has_key('discnumber'):
        filename = os.path.basename(filepath)
        match = regex_search("(^|\D+)(\d)\d\d\D+",filename)
        if match:
            tags['discnumber'] = [int(match.groups()[1])]
            tags['totaldiscs'] = [unicode(totaldiscs(filepath))]
            
    if (tags.has_key('totaldiscs') and
        int(tags['totaldiscs'][0]) == 1):
        del tags['totaldiscs']
        del tags['discnumber']

def guess_albumartist_artist_album(tags,filepath):
    if (tags.has_key('albumartist') and not
        tags.has_key('artist')):
        tags['artist'] = tags['albumartist']
    elif (tags.has_key('artist') and not
          tags.has_key('albumartist')):
        tags['albumartist'] = tags['artist']

    if (not tags.has_key('artist') or
        not tags.has_key('album')):
        dirname = os.path.dirname(filepath)
        files = os.listdir(dirname)
        files = [os.path.splitext(file)[0] for file in files]
        lcs = LongestCommonSubstring(files)
        if not lcs:
            lcs = os.path.basename(dirname)

        match = regex_match('(.*)[ _]-[ _](.*)',lcs)
        if match:
            if not tags.has_key('artist'):
                tags['artist'] = [match.group(1).strip()]
            if not tags.has_key('album'):
                tags['album'] = [match.group(2).strip()]
        else:
            if not tags.has_key('album'):
                tags['album'] = [lcs.strip()]
            elif not tags.has_key('artist'):
                tags['artist'] = [lcs.strip()]

def guess_title(tags,filepath):
    if tags.has_key('title'):
        return

    filename = os.path.basename(filepath)
    rv = regex_search(u'(.*?)(\d+)(.*)',filename)
    if (rv and
        tags.has_key('tracknumber') and
        int(rv.group(2)) == int(tags['tracknumber'][0])):
        tags['title'] = [rv.group(3).strip()]
    else:
        tags['title'] = [unicode(filename.strip())]

    if tags.has_key('albumartist'):
        list = [tags['title'][0],tags['albumartist'][0]]
        lcs = LongestCommonSubstring(list)
        tags['title'][0] = tags['title'][0].replace(lcs,'')
    if tags.has_key('artist'):
        list = [tags['title'][0],tags['artist'][0]]
        lcs = LongestCommonSubstring(list)
        tags['title'][0] = tags['title'][0].replace(lcs,'')

    tags['title'][0] = tags['title'][0].strip(' _-')

def guess_category(tags,filepath):
    if tags.has_key('category'):
        return

    if tags.has_key('album'):
        category = scrape_category(tags['album'][0])
    else:
        dirname = os.path.dirname(filepath)
        category = scrape_category(dirname)

    tags['category'] = [category]
                                
def guess_date(tags,filepath):
    tryfilepath = True
    if tags.has_key('date'):
        rv = regex_search('(\d\d\d\d)',tags['date'][0])
        if rv:
            tags['date'] = [rv.group(0).strip()]
            tryfilepath  = False

    if tryfilepath:
        rv = regex_search('(\d\d\d\d)',filepath)
        if rv:
            tags['date'] = [rv.group(0).strip()]
    
def guesstags(filepath):
    tags = {}    

    filepath = os.path.abspath(filepath)
    dirname = os.path.dirname(filepath)    
    filename = os.path.basename(filepath)
    filename,ext = os.path.splitext(filename)

    files = os.listdir(dirname)
    files.remove(filename+ext)    
    files = [os.path.join(dirname,file) for file in files]

    tags = scrapetagsfrom(files)
    for tag in UNIQUETAGS:
        if tag in tags:
            del tags[tag]
    tags.update(scrapetagsfrom([filepath]))

    pathtags = parsetagsfromdirpath(filepath)
    tags.update(pathtags)

    guess_tracknumber_totaltracks(tags,filepath)
    guess_discnumber_totaldiscs(tags,filepath)
    guess_albumartist_artist_album(tags,filepath)
    guess_title(tags,filepath)
    guess_category(tags,filepath)
    guess_date(tags,filepath)

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

    albumartist = tags['albumartist'][0]
    split = albumartist.split()
    if split[0].lower() in ['a','the']:
        char = split[1][0]
    else:
        char = split[0][0]
    
    if tags.has_key('category'):
        category = tags['category'][0]
    else:
        category = scrape_category(tags)

    album = tags['album'][0]
    if tags.has_key('date'):
        date = tags['date'][0]
        if tags.has_key('release'):
            release = tags['release'][0]
        else:
            path = os.path.join(base,char,albumartist,category)
            release = findnextrelease(path,date,album)
        album = date + release + u'=' + album
    else:
        album = tags['album'][0]

    if tags.has_key('discsubtitle'):
        album += u'_[' + tags['discsubtitle'][0] + u']'
        
    if (tags.has_key('originaldate') and not
        tags.has_key('originalartist') and not
        tags.has_key('originalalbum')):
        album += u'_{'+tags['originaldate'][0]+u'}'

    filename = tags['title'][0]
    if tags.has_key('tracknumber'):
        filename = tags['tracknumber'][0] + u'=' + filename
        if tags.has_key('discnumber'):        
            filename = tags['discnumber'][0] + u'.' + filename

    if (tags.has_key('artist') and
        albumartist != tags['artist'][0]):
        filename += u'_[' + tags['artist'][0] + u']'
        
    if tags.has_key('originalartist'):
        filename += u'_{' + tags['originalartist'][0]
        if tags.has_key('originaldate'):
            filename += u'|' + tags['originaldate'][0]
        if tags.has_key('originalalbum'):
            filename += u'|' + tags['originalalbum'][0]
        filename += u'}'

    if tags.has_key('remixer'):
        filename += u'_<' + tags['remixer'][0] +u'>'

    filename += ext

    albumartist = regex_sub(r'[_ ]*/[_ ]*',r'_-_',albumartist)
    category    = regex_sub(r'[_ ]*/[_ ]*',r'_-_',category)
    album       = regex_sub(r'[_ ]*/[_ ]*',r'_-_',album)
    filename    = regex_sub(r'[_ ]*/[_ ]*',r'_-_',filename)

    path = os.path.join(base,char,albumartist,category,album,filename)

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
            match = regex_match(pattern2,file)
            if match:
                return match.groups()[0]
            match = regex_match(pattern,file)
            if match:
                match = match.groups()[0]
                if match > rv:
                    rv = match
        return unichr(ord(rv)+1)
    else:
        return 'A'

def scrape_category(string):
    album = string.lower()
    if regex_search('[\s(]*single[)\s]*',album):
        return u'Single'
    elif regex_search('[\s(]*ep[)\s]*',album):
        return u'EP'
    elif regex_search('[\s(]*demo[)\s]*',album):
        return u'Demo'
    elif regex_search('[\s(]*live[)\s]*',album):
        return u'Live'
    elif regex_search('[\s(]*remix[)\s]*',album):
        return u'Remix'
    elif regex_search('[\s(]*promo[)\s]*',album):
        return u'Promo'
    elif regex_search('[\s(]*ost[)\s]*',album):
        return u'Soundtrack'
    elif regex_search('[\s(]*soundtrack[)\s]*',album):
        return u'Soundtrack'        
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

def sanitize_tags(tags):
    if tags.has_key('date'):
        rv = regex_search('(\d\d\d\d)',tags['date'][0])
        if rv:
            tags['date'] = [rv.group(0).strip()]

    if tags.has_key('tracknumber'):
        split = tags['tracknumber'][0].split('/')
        if len(split) >= 2:
            tags['tracknumber'] = [unicode(split[0])]
            if not tags.has_key('totaltracks'):
                tags['totaltracks'] = [unicode(split(1))]

def regex_sub(frompattern,topattern,string):
    return re.sub(frompattern,topattern,string,flags=re.UNICODE)
                
def regex_search(pattern,string):
    return re.search(pattern,string,re.UNICODE)

def regex_match(pattern,string):
    return re.match(pattern,string,re.UNICODE)
                       
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

def usage():
    print "usage: %(name)s [opts] [filepath] ..." % {'name':sys.argv[0]}
    print
    print " -h | --help              : print this help/usage"
    print " -e | --exec              : execute (defaults to dry run)"
    print " -p | --print             : print info"
    print " -c | --clear             : clear tags before writing new ones"
    print " -g | --guess             : guess tags not in expected path format"
    print "    | --copy=<path>       : copy to standard path"
    print "    | --delete            : delete once copied"
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
