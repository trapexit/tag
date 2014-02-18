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
from collections import defaultdict


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

    target = {}
    fsenc = sys.getfilesystemencoding()
    for path in args:
        path = os.path.abspath(path)
        if os.path.isdir(path):
            target[path] = path
            for root,dirs,files in os.walk(path.encode(fsenc)):
                for dir in dirs:
                    fullpath = os.path.join(root,dir)
                    target[fullpath] = fullpath
        elif os.path.isfile(path):
            target[path] = os.path.dirname(path)
        else:
            pass

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
               'set':{},'unset':[],'alter':defaultdict(list)}
    
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
            options['alter'][key.lower()].append(value)
        elif opt in ('-h','--help'):
            usage()
            sys.exit(1)

    return options,args

def tagfile(args,filepath):
    dirname  = os.path.dirname(filepath)
    filename,ext = os.path.splitext(filepath)
    if not ext.lower() in ALLOWEDEXTS:
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
        print u'From:',filepath
    if args['copy']:
        newpath = createfilepathfromtags(args['copy'],tags,ext)
        if not newpath:
            return

        if tags:
            tags.update(totals(filepath))
        tags.update(padnumerictags(tags))                    
        if args['print']:
            print u'To:',newpath
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
                    copy_image(filepath,newpath)
                    filepath = newpath
            except Exception as e:
                if not os.path.exists(newpath):
                    print "Error creating path:",os.path.dirname(newpath)
                else:
                    print "Error:",e
    try:
        audio = mutagen.File(filepath)
        if audio != None:
            apply_tags(audio,tags,args['clear'])
            if args['print']:
                print_tags(tags)
                print ''

            if args['exec']:
                s = os.stat(filepath)
                os.chmod(filepath, s.st_mode | stat.S_IWUSR)
                add_images_from_dir(audio)
                audio.save()
                os.chmod(filepath, s.st_mode)
    except Exception as e:
        print "Error:",e,filepath
        
    return

def apply_tags(audio,tags,clear):
    if audio == None:
        return

    if clear:
        cleartags(audio)
    set_tags(audio,tags)

def print_tags(tags):
    maxlen = max([len(key) for key,value in tags.items()])
    for key,values in sorted(tags.items()):
        for value in values:
            print '%-*s = %s' % (maxlen,key.upper(),value)

def copy_image(oldpath,newpath):
    if not os.path.isdir(oldpath):
        oldpath = os.path.dirname(oldpath)
    if not os.path.isdir(newpath):
        newpath = os.path.dirname(newpath)

    bestfile = None
    files = {file.lower():file for file in os.listdir(oldpath)}
    for name in ['cover','folder','front']:
        for ext in ['.png','.jpg','.jpeg','.gif']:
            if name+ext in files:
                bestfile = files[name+ext]

    if bestfile == None:
        for lfile,file in files.items():
            filename,ext = os.path.splitext(file)
            ext = ext.lower()
            if ext in ['.png','.jpg','.jpeg','.gif']:
                bestfile = file
                break

    if bestfile:
        filename,ext = os.path.splitext(bestfile)
        source = os.path.join(oldpath,bestfile)
        target = os.path.join(newpath,'cover'+ext.lower())
        try:
            shutil.copyfile(source,target)
        except:
            pass
        return target

    return None

def add_images_from_dir(audio):
    if type(audio) != mutagen.flac.FLAC:
        return

    filepath = os.path.abspath(audio.filename)
    dirname  = os.path.dirname(filepath)

    files = os.listdir(dirname)
    for ext in ['.png','.jpeg','.jpg','.gif']:
        if 'cover'+ext in files:
            imagepath = os.path.join(dirname,'cover'+ext)
            add_image(audio,imagepath)
            return
    
def add_image(audio,imagepath):
    image = mutagen.flac.Picture()
    with open(imagepath,'rb') as f:
        image.data = f.read()
        audio.add_picture(image)
        f.close()

def cleartags(audio):
    sf = None
    if audio.has_key('source_format'):
        sf = audio['source_format']
    elif audio.has_key('sourceformat'):
        sf = audio['sourceformat']
    audio.clear()
    if sf:
        audio['sourceformat'] = sf

def set_tags(audio,tags):
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

#    if tags.has_key('discnumber'):
#        if tags.has_key('totaldiscs'):
#            tags['discnumber'] = [padnumber(tags['discnumber'][0],
#                                            tags['totaldiscs'][0])]
#        else:
#            tags['discnumber'] = [padnumber(tags['discnumber'][0])]

#    if tags.has_key('totaldiscs'):
#        tags['totaldiscs'] = [padnumber(tags['totaldiscs'][0])]

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

    if (not filetags.has_key('artist') and
        dirtags.has_key('albumartist')):
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
        if ext.lower() in ALLOWEDEXTS:
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

def guess_tracknumber(filename):
    nums = regex_findall('\d+',filename)
    values = {}
    for num in nums:
        values[len(num)] = num

    if 2 in values:
        return unicode(values[2])
    if 3 in values:
        return unicode(values[3][1:])
    if 1 in values:
        return unicode(values[1])
    return None

def guess_tracknumber_totaltracks(tags,filepath):
    filepath     = os.path.abspath(filepath)
    dirname      = os.path.dirname(filepath)
    filename     = os.path.basename(filepath)
    filename,ext = os.path.splitext(filename)

    if (not tags.has_key('tracknumber') or
        int(tags['tracknumber'][0].split('/')[0]) == 0 or
        not tags['tracknumber'][0]) :
        tracknumber = guess_tracknumber(filename)
        if tracknumber:
            tags['tracknumber'] = [tracknumber]

    if tags.has_key('tracknumber'):
        split = tags['tracknumber'][0].split('/')
        if len(split) == 2:
            tags['tracknumber'] = [unicode(split[0])]
            if not tags.has_key('totaltracks'):
                tags['totaltracks'] = [unicode(split[1])]
            else:
                total = totaltracks(filepath)
                tags['totaltracks'] = [unicode(total)]

    if (tags.has_key('tracknumber') and not
        tags['tracknumber'][0].isdigit()):
        files = os.listdir(dirname)
        files.sort()
        total       = 0
        tracknumber = 0
        for file in files:
            tmpfilename,tmpext = os.path.splitext(file)
            if tmpext == ext:
                total += 1
                if tmpfilename == filename:
                    tracknumber = total
        tags['tracknumber'] = [unicode(tracknumber)]
        tags['totaltracks'] = [unicode(totaltracks)]
            
def guess_discnumber_totaldiscs(tags,filepath):
    if (not tags.has_key('totaldiscs') and
        tags.has_key('discnumber')):
        split = tags['discnumber'][0].split('/')
        if len(split) == 2:
            tags['discnumber'] = [unicode(split[0])]
            tags['totaldiscs'] = [unicode(split[1])]

    if not tags.has_key('discnumber'):
        match = regex_search('[cC][dD](\d)',filepath)
        if match:
            tags['discnumber'] = [unicode(match.group(1))]
            
    if not tags.has_key('discnumber'):
        filename = os.path.basename(filepath)
        match = regex_search("(^|\D+)(\d)\d\d\D+",filename)
        if match:
            tags['discnumber'] = [unicode(match.group(1))]
            
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
        ext = os.path.splitext(filepath)[1].lower()
        files = os.listdir(dirname)
        files = [os.path.splitext(file)[0]
                 for file in files
                 if os.path.splitext(file)[1].lower() == ext]
        lcs = LongestCommonSubstring(files)
        if not lcs:
            lcs = os.path.basename(dirname)

        split = clean_filename(lcs)
        if not tags.has_key('artist') and split:
            tags['artist'] = [split.pop(0)]
        if not tags.has_key('album') and split:
            tags['album'] = [split.pop(0)]

    if (tags.has_key('artist') and
        not tags.has_key('albumartist')):
        tags['albumartist'] = tags['artist']

def guess_title(tags,filepath):
    if tags.has_key('title'):
        return

    filename     = os.path.basename(filepath)
    filename,ext = os.path.splitext(filename)

    title = filename

    if tags.has_key('albumartist'):
        list = [title,tags['albumartist'][0]]
        lcs = LongestCommonSubstring(list)
        title = title.replace(lcs,'')
    if tags.has_key('artist'):
        list = [title,tags['artist'][0]]
        lcs = LongestCommonSubstring(list)
        title = title.replace(lcs,'')
    
    if tags.has_key('tracknumber'):
        tn = tags['tracknumber'][0]
        rv = regex_search(u'.*?'+tn+'(.*)',filename)
        if rv:
            title = rv.group(1)

    tags['title'] = [title.strip(' _-')]

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
            tags['date'] = [rv.group(1).strip()]
            tryfilepath  = False

    if tryfilepath:
        rv = regex_search('(\d\d\d\d)',filepath)
        if rv:
            tags['date'] = [rv.group(1).strip()]
    
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
        if not ext.lower() in ALLOWEDEXTS:
            continue
        try:
            audio = mutagen.File(filepath)
            if not audio:
                continue
            for tag in IMPORTANTTAGS:
                if (not tags.has_key(tag) and
                    audio.has_key(tag)    and
                    audio[tag][0].strip()):
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

def clean_filename(filename):
    filename = re.sub('[^\w\s\'\,\.\!\?]+','|',filename)
    filename = re.sub('\s*\|\s*','|',filename)
    filename = re.sub('\|+','|',filename)
    return [v for v in filename.split('|') if v]
        
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

def altertags(alters,tags):
    newtags = {}
    for key,ops in alters.items():
        if tags.has_key(key):
            newtags[key] = []
            for tagvalue in tags[key]:
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
                        split = op.split(op[1])
                        if len(split) == 3:
                            tagvalue = tagvalue.replace(split[1],split[2])
                    elif op[0] == 'a' and op[1] == ':':
                        tagvalue = tagvalue + op[2:]
                    elif op[0] == 'p' and op[1] == ':':
                        tagvalue = op[2:] + tagvalue
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

def regex_findall(pattern,string):
    return re.findall(pattern,string,re.UNICODE)
                       
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
    print "  <mod> = "
    print "  t = title capitalization"
    print "  c = capitalize first letter"
    print "  l = lowercase"
    print "  u = uppercase"
    print "  s = swapcase"
    print "  a:<str> = append str to value"
    print "  p:<str> = prepend str to value"
    print "  r<sep>oldvalue<sep>newvalue = replace 'oldvalue' with 'newvalue'"
    print "  <sep> is arbitrary, the char after 'r' is the token to split"
    print

if __name__ == "__main__":
    main()
