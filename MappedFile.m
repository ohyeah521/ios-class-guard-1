//
// $Id: MappedFile.m,v 1.2 1999/08/09 06:52:23 nygard Exp $
//

//
//  This file is a part of class-dump v2, a utility for examining the
//  Objective-C segment of Mach-O files.
//  Copyright (C) 1997, 1998, 1999  Steve Nygard
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
//
//  You may contact the author by:
//     e-mail:  nygard@telusplanet.net
//

#import "MappedFile.h"
#if NS_TARGET_MAJOR < 4 && !defined(__APPLE__)
#import <foundation/NSArray.h>
#import <foundation/NSException.h>
#import <foundation/NSPathUtilities.h>
#import <foundation/NSUtilities.h>

@interface NSString (Foundation4PathCompatibility)
- (NSArray *)pathComponents;
@end

@implementation NSString (Foundation4PathCompatibility)
- (NSArray *)pathComponents
{
   return [self componentsSeparatedByString:@"/"];
}
@end

#endif

#include <stdio.h>
#include <libc.h>
#include <ctype.h>

static NSArray *envDyldFrameworkPath = nil;
static NSArray *envDyldLibraryPath = nil;
static NSArray *envDyldFallbackFrameworkPath = nil;
static NSArray *envDyldFallbackLibraryPath = nil;
static NSMutableArray *firstSearchPath = nil;
static NSMutableArray *secondSearchPath = nil;

@implementation MappedFile

+ (void) initialize
{
    static BOOL initialized = NO;
    NSDictionary *environment;
    NSString *home;

    if (initialized == YES)
        return;
    initialized = YES;

    environment = [[NSProcessInfo processInfo] environment];
    envDyldFrameworkPath = [[environment objectForKey:@"DYLD_FRAMEWORK_PATH"] componentsSeparatedByString:@":"];
    envDyldLibraryPath = [[environment objectForKey:@"DYLD_LIBRARY_PATH"] componentsSeparatedByString:@":"];
    envDyldFallbackFrameworkPath = [[environment objectForKey:@"DYLD_FALLBACK_FRAMEWORK_PATH"] componentsSeparatedByString:@":"];
    envDyldFallbackLibraryPath = [[environment objectForKey:@"DYLD_FALLBACK_LIBRARY_PATH"] componentsSeparatedByString:@":"];
    home = [environment objectForKey:@"HOME"];

    //NSLog (@"envDyldFrameworkPath: %@", envDyldFrameworkPath);
    //NSLog (@"envDyldLibraryPath: %@", envDyldLibraryPath);

    //NSLog (@"envDyldFallbackFrameworkPath: %@", envDyldFallbackFrameworkPath);
    if (envDyldFallbackFrameworkPath == nil)
        envDyldFallbackFrameworkPath = [[NSArray arrayWithObjects:[NSString stringWithFormat:@"%@/Library/Frameworks", home],
                                                 @"/Local/Library/Frameworks",
                                                 @"/Network/Library/Frameworks",
                                                 @"/System/Library/Frameworks",
                                                 @"/LocalLibrary/Frameworks",
                                                 @"/NextLibrary/Frameworks",
                                                 nil] retain];
    //NSLog (@"envDyldFallbackFrameworkPath: %@", envDyldFallbackFrameworkPath);

    //NSLog (@"envDyldFallbackLibraryPath: %@", envDyldFallbackLibraryPath);
    if (envDyldFallbackLibraryPath == nil)
        envDyldFallbackLibraryPath = [[NSArray arrayWithObjects:[NSString stringWithFormat:@"%@/lib", home],
                                               @"/usr/local/lib",
                                               @"/lib",
                                               @"/usr/lib",
                                               nil] retain];
    //NSLog (@"envDyldFallbackLibraryPath: %@", envDyldFallbackLibraryPath);

    firstSearchPath = [[NSMutableArray arrayWithArray:envDyldFrameworkPath] retain];
    [firstSearchPath addObjectsFromArray:envDyldLibraryPath];

    secondSearchPath = [[NSMutableArray arrayWithArray:envDyldFallbackFrameworkPath] retain];
    [secondSearchPath addObjectsFromArray:envDyldFallbackLibraryPath];
}

// Will map filename into memory.  If filename is a directory with specific suffixes, treat the directory as a wrapper.

- initWithFilename:(NSString *)aFilename
{
    NSString *standardPath;
#if (NS_TARGET_MAJOR >= 4)
    NSMutableSet *wrappers = [NSMutableSet set];
#else
    // for foundation 3.x (less efficient than a set but at least it works...)
    NSMutableArray *wrappers = [NSMutableArray array];
#endif
    if ([super init] == nil)
        return nil;

    standardPath = [aFilename stringByStandardizingPath];

    // XXX: Try grabbing these from an environment variable & move to +initialize
    [wrappers addObject:@"app"];
    [wrappers addObject:@"framework"];
    [wrappers addObject:@"bundle"];
    [wrappers addObject:@"palette"];
    [wrappers addObject:@"plugin"];

    if ([wrappers containsObject:[standardPath pathExtension]] == YES)
    {
        standardPath = [self pathToMainFileOfWrapper:standardPath];
    }

    //NSLog (@"before: %@", standardPath);
    filename = [self adjustedFrameworkPath:standardPath];
    //NSLog (@"after:  %@", standardPath);

    data = [[NSData dataWithContentsOfMappedFile:filename] retain];
    if (data == nil)
    {
        NSLog (@"Couldn't map file: %@", filename);
        return nil;
    }

    installName = [standardPath retain];
    filename = [filename retain];

    return self;
}

- (void) dealloc
{
    [data release];
    [filename release];
    [installName release];

    [super dealloc];
}

- (NSString *) installName
{
    return installName;
}

- (NSString *) filename
{
    return filename;
}

- (const void *) data
{
    return [data bytes];
}

// How does this handle something ending in "/"?

- (NSString *) pathToMainFileOfWrapper:(NSString *)path
{
    NSRange range;
    NSMutableString *tmp;
    NSString *extension;
    NSString *base;

    base = [[path pathComponents] lastObject];
    NSAssert (base != nil, @"No base.");
    
    extension = [NSString stringWithFormat:@".%@", [base pathExtension]];

    tmp = [NSMutableString stringWithFormat:@"%@/%@", path, base];
    range = [tmp rangeOfString:extension options:NSBackwardsSearch];
    [tmp deleteCharactersInRange:range];

    return tmp;
}

- (NSString *) adjustedFrameworkPath:(NSString *)path
{
    NSArray *pathComponents;
    int count, l;
    NSString *tailString = nil, *frameworkName = nil, *version = nil;
    NSRange tailRange;
    NSString *adjustedPath;
    NSFileManager *fileManager;

    pathComponents = [path pathComponents];
    count = [pathComponents count];
    if (count - 1 >= 0)
        frameworkName = [pathComponents objectAtIndex:count - 1];

    if (count - 3 >= 0)
    {
        if ([[pathComponents objectAtIndex:count - 3] isEqual:@"Versions"] == YES)
            version = [pathComponents objectAtIndex:count - 2];
    }

    //NSLog (@"frameworkName: %@", frameworkName);
    if (frameworkName == nil)
        return path;

    //NSLog (@"version: %@", version);
    if (version == nil)
        tailString = [NSString stringWithFormat:@"%@.framework/%@", frameworkName, frameworkName];
    else
        tailString = [NSString stringWithFormat:@"%@.framework/Versions/%@/%@", frameworkName, version, frameworkName];

    //NSLog (@"tailString: %@", tailString);

    tailRange = [path rangeOfString:tailString options:NSBackwardsSearch];
    //NSLog (@"tailRange.length: %d", tailRange.length);
    if (tailRange.length == 0)
        return path;

    fileManager = [NSFileManager defaultManager];

    count = [firstSearchPath count];
    for (l = 0; l < count; l++)
    {
        adjustedPath = [NSString stringWithFormat:@"%@/%@", [firstSearchPath objectAtIndex:l], tailString];
        //NSLog (@"adjustedPath: %@", adjustedPath);
        if ([fileManager fileExistsAtPath:adjustedPath] == YES)
            return adjustedPath;
    }

    count = [secondSearchPath count];
    for (l = 0; l < count; l++)
    {
        adjustedPath = [NSString stringWithFormat:@"%@/%@", [secondSearchPath objectAtIndex:l], tailString];
        //NSLog (@"adjustedPath: %@", adjustedPath);
        if ([fileManager fileExistsAtPath:adjustedPath] == YES)
            return adjustedPath;
    }

    return path;
}

@end
