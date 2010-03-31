//
//  $Id$
//
//  TableDocument.m
//  sequel-pro
//
//  Created by lorenz textor (lorenz@textor.ch) on Wed May 01 2002.
//  Copyright (c) 2002-2003 Lorenz Textor. All rights reserved.
//  
//  Forked by Abhi Beckert (abhibeckert.com) 2008-04-04
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
//  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
//
//  More info at <http://code.google.com/p/sequel-pro/>

#import "TableDocument.h"
#import "TablesList.h"
#import "TableSource.h"
#import "TableContent.h"
#import "CustomQuery.h"
#import "TableDump.h"
#import "ImageAndTextCell.h"
#import "SPGrowlController.h"
#import "SPExportController.h"
#import "SPQueryController.h"
#import "SPNavigatorController.h"
#import "SPSQLParser.h"
#import "SPTableData.h"
#import "SPDatabaseData.h"
#import "SPStringAdditions.h"
#import "SPArrayAdditions.h"
#import "SPDataAdditions.h"
#import "SPAppController.h"
#import "SPExtendedTableInfo.h"
#import "SPConnectionController.h"
#import "SPHistoryController.h"
#import "SPPreferenceController.h"
#import "SPUserManager.h"
#import "SPEncodingPopupAccessory.h"
#import "SPConstants.h"
#import "YRKSpinningProgressIndicator.h"
#import "SPProcessListController.h"
#import "SPServerVariablesController.h"
#import "SPAlertSheets.h"
#import "SPConstants.h"
#import "SPMainThreadTrampoline.h"

@interface TableDocument (PrivateAPI)

- (void)_addDatabase;
- (void)_removeDatabase;
- (void)_selectDatabaseAndItem:(NSDictionary *)selectionDetails;

@end

@implementation TableDocument

- (id)init
{
	
	if ((self = [super init])) {

		_mainNibLoaded = NO;
		_encoding = [[NSString alloc] initWithString:@"utf8"];
		_isConnected = NO;
		_isWorkingLevel = 0;
		databaseListIsSelectable = YES;
		_queryMode = SPInterfaceQueryMode;
		chooseDatabaseButton = nil;
		chooseDatabaseToolbarItem = nil;
		connectionController = nil;
		selectedDatabase = nil;
		mySQLConnection = nil;
		mySQLVersion = nil;
		allDatabases = nil;
		allSystemDatabases = nil;

		printWebView = [[WebView alloc] init];
		[printWebView setFrameLoadDelegate:self];

		prefs = [NSUserDefaults standardUserDefaults];
		queryEditorInitString = nil;

		spfSession = nil;
		spfPreferences = [[NSMutableDictionary alloc] init];
		spfDocData = [[NSMutableDictionary alloc] init];

		taskProgressWindow = nil;
		taskDisplayIsIndeterminate = YES;
		taskDisplayLastValue = 0;
		taskProgressValue = 0;
		taskProgressValueDisplayInterval = 1;
		taskDrawTimer = nil;
		taskFadeAnimator = nil;
		taskCanBeCancelled = NO;
		taskCancellationCallbackObject = nil;
		taskCancellationCallbackSelector = NULL;

		keyChainID = nil;
		statusValues = nil;
		printThread = nil;
	}

	return self;
}

- (void)awakeFromNib
{
	if (_mainNibLoaded) return;
	_mainNibLoaded = YES;

	// The first window should use autosaving; subsequent windows should cascade
	BOOL usedAutosave = [tableWindow setFrameAutosaveName:[self windowNibName]];
	if (!usedAutosave) {
		[tableWindow setFrameUsingName:[self windowNibName]];
		NSArray *documents = [[NSDocumentController sharedDocumentController] documents];
		NSRect previousFrame = [[[documents objectAtIndex:(([documents count] > 1)?[documents count]-2:[documents count]-1)] valueForKey:@"tableWindow"] frame];
		NSPoint topLeftPoint = previousFrame.origin;
		topLeftPoint.y += previousFrame.size.height;
		[tableWindow setFrameTopLeftPoint:[tableWindow cascadeTopLeftFromPoint:topLeftPoint]];

		// Try to check if new frame fits into the screen
		NSRect screenFrame = [[NSScreen mainScreen] frame];
		NSScreen* candidate;
		for(candidate in [NSScreen screens])
			if(NSMinX([candidate frame]) < topLeftPoint.x && NSMinX([candidate frame]) > NSMinX(screenFrame))
				screenFrame = [candidate visibleFrame];

		previousFrame = [tableWindow frame];

		// Determine if move/resize is required
		if(previousFrame.origin.x - screenFrame.origin.x + previousFrame.size.width >= screenFrame.size.width
			|| previousFrame.origin.y - screenFrame.origin.y + previousFrame.size.height >= screenFrame.size.height)
		{

			// First try to move the window back onto the screen if it will fit
			if (previousFrame.size.width <= screenFrame.size.width && previousFrame.size.height <= screenFrame.size.height) {
				previousFrame.origin.x -= (previousFrame.origin.x + previousFrame.size.width) - (screenFrame.origin.x + screenFrame.size.width);
				previousFrame.origin.y -= (previousFrame.origin.y + previousFrame.size.height) - (screenFrame.origin.y + screenFrame.size.height);
				[tableWindow setFrame:previousFrame display:YES];

			// Otherwise, resize and de-cascade a little
			} else {
				previousFrame.size.width -= 50;
				previousFrame.size.height -= 50;
				previousFrame.origin.y += 50;
				if(previousFrame.size.width >= [tableWindow minSize].width && previousFrame.size.height >= [tableWindow minSize].height)
					[tableWindow setFrame:previousFrame display:YES];
			}
		}

	}

	// Set up the toolbar
	[self setupToolbar];

	// Set up the connection controller
	connectionController = [[SPConnectionController alloc] initWithDocument:self];
	
	// Set the connection controller's delegate
	[connectionController setDelegate:self];
	
	// Register observers for when the DisplayTableViewVerticalGridlines preference changes
	[prefs addObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:tableSourceInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:tableContentInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:customQueryInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:tableRelationsInstance forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:[SPQueryController sharedQueryController] forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];

	// Register observers for the when the UseMonospacedFonts preference changes
	[prefs addObserver:tableSourceInstance forKeyPath:SPUseMonospacedFonts options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:tableContentInstance forKeyPath:SPUseMonospacedFonts options:NSKeyValueObservingOptionNew context:NULL];
	// [prefs addObserver:customQueryInstance forKeyPath:SPUseMonospacedFonts options:NSKeyValueObservingOptionNew context:NULL];
	[prefs addObserver:[SPQueryController sharedQueryController] forKeyPath:SPUseMonospacedFonts options:NSKeyValueObservingOptionNew context:NULL];

	[prefs addObserver:tableContentInstance forKeyPath:SPGlobalResultTableFont options:NSKeyValueObservingOptionNew context:NULL];

	// Register observers for when the logging preference changes
	[prefs addObserver:[SPQueryController sharedQueryController] forKeyPath:SPConsoleEnableLogging options:NSKeyValueObservingOptionNew context:NULL];

	// Register a second observer for when the logging preference changes so we can tell the current connection about it
	[prefs addObserver:self forKeyPath:SPConsoleEnableLogging options:NSKeyValueObservingOptionNew context:NULL];

	// Find the Database -> Database Encoding menu (it's not in our nib, so we can't use interface builder)
	selectEncodingMenu = [[[[[NSApp mainMenu] itemWithTag:1] submenu] itemWithTag:1] submenu];

	// Hide the tabs in the tab view (we only show them to allow switching tabs in interface builder)
	[tableTabView setTabViewType:NSNoTabsNoBorder];

	// Add the icon accessory view to the title bar
	NSView *windowFrame = [[tableWindow contentView] superview];
	NSRect av = [titleAccessoryView frame];
	NSRect initialAccessoryViewFrame = NSMakeRect(
											[windowFrame frame].size.width - av.size.width - 30,
											[windowFrame frame].size.height - av.size.height,
											av.size.width,
											av.size.height);
	[titleAccessoryView setFrame:initialAccessoryViewFrame];
	[windowFrame addSubview:titleAccessoryView];

	// Bind the background color of the create syntax text view to the users preference
	[createTableSyntaxTextView setAllowsDocumentBackgroundColorChange:YES];

	NSMutableDictionary *bindingOptions = [NSMutableDictionary dictionary];

	[bindingOptions setObject:NSUnarchiveFromDataTransformerName forKey:@"NSValueTransformerName"];

	[createTableSyntaxTextView bind:@"backgroundColor"
						   toObject:[NSUserDefaultsController sharedUserDefaultsController]
						withKeyPath:@"values.CustomQueryEditorBackgroundColor"
							options:bindingOptions];

	// Load additional nibs
	if (![NSBundle loadNibNamed:@"ConnectionErrorDialog" owner:self]) {
		NSLog(@"Connection error dialog could not be loaded; connection failure handling will not function correctly.");
	}
	if (![NSBundle loadNibNamed:@"ProgressIndicatorLayer" owner:self]) {
		NSLog(@"Progress indicator layer could not be loaded; progress display will not function correctly.");
	}

	// Set up the progress indicator child window and layer - add to main window, change indicator color and size
	[taskProgressIndicator setForeColor:[NSColor whiteColor]];
	taskProgressWindow = [[NSWindow alloc] initWithContentRect:[taskProgressLayer bounds] styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
	[taskProgressWindow setOpaque:NO];
	[taskProgressWindow setBackgroundColor:[NSColor clearColor]];
	[taskProgressWindow setAlphaValue:0.0];
	[taskProgressWindow orderFront:self];
	[tableWindow addChildWindow:taskProgressWindow ordered:NSWindowAbove];
	[taskProgressWindow release];
	[taskProgressWindow setContentView:taskProgressLayer];
	[self centerTaskWindow];
}

/**
 * Initialise the document with the connection file at the supplied path.
 */
- (void)initWithConnectionFile:(NSString *)path
{
	NSError *readError = nil;
	NSString *convError = nil;
	NSPropertyListFormat format;

	NSString *encryptpw = nil;
	NSDictionary *data = nil;
	NSDictionary *connection = nil;
	NSDictionary *spf = nil;

	NSInteger connectionType = -1;

	// Inform about the data source in the window title bar
	[tableWindow setTitle:[self displaySPName]];

	// Clean fields
	[connectionController setName:@""];
	[connectionController setUser:@""];
	[connectionController setHost:@""];
	[connectionController setPort:@""];
	[connectionController setSocket:@""];
	[connectionController setSshHost:@""];
	[connectionController setSshUser:@""];
	[connectionController setSshPort:@""];
	[connectionController setDatabase:@""];
	[connectionController setPassword:@""];
	[connectionController setSshPassword:@""];

	// Deselect all favorites
	[[connectionController valueForKeyPath:@"favoritesTable"] deselectAll:connectionController];
	// Suppress the possibility to choose an other connection from the favorites
	// if a connection should initialized by SPF file. Otherwise it could happen
	// that the SPF file runs out of sync.
	[[connectionController valueForKeyPath:@"favoritesTable"] setEnabled:NO];


	NSData *pData = [NSData dataWithContentsOfFile:path options:NSUncachedRead error:&readError];

	spf = [[NSPropertyListSerialization propertyListFromData:pData 
			mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&convError] retain];

	if(!spf || readError != nil || [convError length] || !(format == NSPropertyListXMLFormat_v1_0 || format == NSPropertyListBinaryFormat_v1_0)) {
		NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										  otherButton:nil 
							informativeTextWithFormat:NSLocalizedString(@"Connection data file couldn't be read.", @"error while reading connection data file")];

		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		if (spf) [spf release];
		[self close];
		return;
	}

	// For dispatching later
	if(![[spf objectForKey:@"format"] isEqualToString:@"connection"]) {
		NSLog(@"SPF file format is not 'connection'.");
		[spf release];
		[self close];
		return;
	}

	if(![spf objectForKey:@"data"]) {
		NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										  otherButton:nil 
							informativeTextWithFormat:NSLocalizedString(@"No data found.", @"no data found")];

		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		[spf release];
		[self close];
		return;
	}

	// Ask for a password if SPF file passwords were encrypted as sheet
	if([spf objectForKey:@"encrypted"] && [[spf valueForKey:@"encrypted"] boolValue]) {

		[inputTextWindowHeader setStringValue:NSLocalizedString(@"Connection file is encrypted", @"Connection file is encrypted")];
		[inputTextWindowMessage setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Enter password for ‘%@’:",@"Please enter the password"), [path lastPathComponent]]];
		[inputTextWindowSecureTextField setStringValue:@""];
		[inputTextWindowSecureTextField selectText:nil];

		[NSApp beginSheet:inputTextWindow modalForWindow:tableWindow modalDelegate:self didEndSelector:nil contextInfo:nil];

		// wait for encryption password
		NSModalSession session = [NSApp beginModalSessionForWindow:inputTextWindow];
		for (;;) {

			// Execute code on DefaultRunLoop
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode 
									 beforeDate:[NSDate distantFuture]];

			// Break the run loop if editSheet was closed
			if ([NSApp runModalSession:session] != NSRunContinuesResponse 
				|| ![inputTextWindow isVisible]) 
				break;

			// Execute code on DefaultRunLoop
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode 
									 beforeDate:[NSDate distantFuture]];

		}
		[NSApp endModalSession:session];
		[inputTextWindow orderOut:nil];
		[NSApp endSheet:inputTextWindow];

		if(passwordSheetReturnCode)
			encryptpw = [inputTextWindowSecureTextField stringValue];
		else {
			[self close];
			[spf release];
			return;
		}

	}

	if([[spf objectForKey:@"data"] isKindOfClass:[NSDictionary class]])
		data = [NSDictionary dictionaryWithDictionary:[spf objectForKey:@"data"]];
	else if([[spf objectForKey:@"data"] isKindOfClass:[NSData class]]) {
		NSData *decryptdata = nil;
		decryptdata = [[[NSMutableData alloc] initWithData:[(NSData *)[spf objectForKey:@"data"] dataDecryptedWithPassword:encryptpw]] autorelease];
		if(decryptdata != nil && [decryptdata length]) {
			NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingWithData:decryptdata] autorelease];
			data = (NSDictionary *)[unarchiver decodeObjectForKey:@"data"];
			[unarchiver finishDecoding];
		}
		if(data == nil) {
			NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
											 defaultButton:NSLocalizedString(@"OK", @"OK button") 
										   alternateButton:nil 
											  otherButton:nil 
								informativeTextWithFormat:NSLocalizedString(@"Wrong data format or password.", @"wrong data format or password")];

			[alert setAlertStyle:NSCriticalAlertStyle];
			[alert runModal];
			[self close];
			[spf release];
			return;
		}
	}

	if(data == nil) {
		NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										  otherButton:nil 
							informativeTextWithFormat:NSLocalizedString(@"Wrong data format.", @"wrong data format")];

		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		[self close];
		[spf release];
		return;
	}


	if(![data objectForKey:@"connection"]) {
		NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										  otherButton:nil 
							informativeTextWithFormat:NSLocalizedString(@"No connection data found.", @"no connection data found")];

		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		[self close];
		[spf release];
		return;
	}

	[spfDocData setObject:[NSNumber numberWithBool:NO] forKey:@"encrypted"];
	if(encryptpw != nil) {
		[spfDocData setObject:[NSNumber numberWithBool:YES] forKey:@"encrypted"];
		[spfDocData setObject:encryptpw forKey:@"e_string"];
	}
	encryptpw = nil;

	connection = [NSDictionary dictionaryWithDictionary:[data objectForKey:@"connection"]];

	if([connection objectForKey:@"type"]) {
		if([[connection objectForKey:@"type"] isEqualToString:@"SPTCPIPConnection"])
			connectionType = SPTCPIPConnection;
		else if([[connection objectForKey:@"type"] isEqualToString:@"SPSocketConnection"])
			connectionType = SPSocketConnection;
		else if([[connection objectForKey:@"type"] isEqualToString:@"SPSSHTunnelConnection"])
			connectionType = SPSSHTunnelConnection;
		else
			connectionType = SPTCPIPConnection;

		[connectionController setType:connectionType];
		[connectionController resizeTabViewToConnectionType:connectionType animating:NO];
	}

	if([connection objectForKey:@"name"])
		[connectionController setName:[connection objectForKey:@"name"]];
	if([connection objectForKey:@"user"])
		[connectionController setUser:[connection objectForKey:@"user"]];
	if([connection objectForKey:@"host"])
		[connectionController setHost:[connection objectForKey:@"host"]];
	if([connection objectForKey:@"port"])
		[connectionController setPort:[NSString stringWithFormat:@"%ld", (long)[[connection objectForKey:@"port"] integerValue]]];
	if([connection objectForKey:@"kcid"] && [(NSString *)[connection objectForKey:@"kcid"] length])
		[self setKeychainID:[connection objectForKey:@"kcid"]];

	// Set password - if not in SPF file try to get it via the KeyChain
	if([connection objectForKey:@"password"])
		[connectionController setPassword:[connection objectForKey:@"password"]];
	else {
		NSString *pw = [self keychainPasswordForConnection:nil];
		if([pw length])
			[connectionController setPassword:pw];
	}

	if(connectionType == SPSocketConnection && [connection objectForKey:@"socket"])
		[connectionController setSocket:[connection objectForKey:@"socket"]];

	if(connectionType == SPSSHTunnelConnection) {
		if([connection objectForKey:@"ssh_host"])
			[connectionController setSshHost:[connection objectForKey:@"ssh_host"]];
		if([connection objectForKey:@"ssh_user"])
			[connectionController setSshUser:[connection objectForKey:@"ssh_user"]];
		if([connection objectForKey:@"ssh_port"])
			[connectionController setSshPort:[NSString stringWithFormat:@"%ld", (long)[[connection objectForKey:@"ssh_port"] integerValue]]];

		// Set ssh password - if not in SPF file try to get it via the KeyChain
		if([connection objectForKey:@"ssh_password"])
			[connectionController setSshPassword:[connection objectForKey:@"ssh_password"]];
		else {
			SPKeychain *keychain = [[SPKeychain alloc] init];
			NSString *connectionSSHKeychainItemName = [[keychain nameForSSHForFavoriteName:[connectionController name] id:[self keyChainID]] retain];
			NSString *connectionSSHKeychainItemAccount = [[keychain accountForSSHUser:[connectionController sshUser] sshHost:[connectionController sshHost]] retain];
			NSString *pw = [keychain getPasswordForName:connectionSSHKeychainItemName account:connectionSSHKeychainItemAccount];
			if ([pw length])
				[connectionController setSshPassword:pw];
			if(connectionSSHKeychainItemName) [connectionSSHKeychainItemName release];
			if(connectionSSHKeychainItemAccount) [connectionSSHKeychainItemAccount release];
			[keychain release];
		}

	}

	if([connection objectForKey:@"database"])
		[connectionController setDatabase:[connection objectForKey:@"database"]];

	if([data objectForKey:@"session"]) {
		spfSession = [[NSDictionary dictionaryWithDictionary:[data objectForKey:@"session"]] retain];
		[spfDocData setObject:[NSNumber numberWithBool:YES] forKey:@"include_session"];
	}

	[self setFileURL:[NSURL fileURLWithPath:path]];
	[[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:path]];

	if([spf objectForKey:SPQueryFavorites])
		[spfPreferences setObject:[spf objectForKey:SPQueryFavorites] forKey:SPQueryFavorites];
	if([spf objectForKey:SPQueryHistory])
		[spfPreferences setObject:[spf objectForKey:SPQueryHistory] forKey:SPQueryHistory];
	if([spf objectForKey:SPContentFilters])
		[spfPreferences setObject:[spf objectForKey:SPContentFilters] forKey:SPContentFilters];

	[spfDocData setObject:[NSNumber numberWithBool:([connection objectForKey:@"password"]) ? YES : NO] forKey:@"save_password"];

	[spfDocData setObject:[NSNumber numberWithBool:NO] forKey:@"auto_connect"];

	if([spf objectForKey:@"auto_connect"] && [[spf valueForKey:@"auto_connect"] boolValue]) {
		[spfDocData setObject:[NSNumber numberWithBool:YES] forKey:@"auto_connect"];
		[connectionController initiateConnection:self];
	}
	[spf release];
}

/**
 * Restore session from SPF file if given
 */
- (void)restoreSession
{
	NSAutoreleasePool *taskPool = [[NSAutoreleasePool alloc] init];

	// Check and set the table
	NSArray *tables = [tablesListInstance tables];

	if([tables indexOfObject:[spfSession objectForKey:@"table"]] == NSNotFound) {
		[self endTask];
		[taskPool drain];
		return;
	}

	// Restore toolbar setting
	if([spfSession objectForKey:@"isToolbarVisible"])
		[[tableWindow toolbar] setVisible:[[spfSession objectForKey:@"isToolbarVisible"] boolValue]];

	// TODO up to now it doesn't work
	if([spfSession objectForKey:@"contentSelectedIndexSet"]) {
		NSMutableIndexSet *anIndexSet = [NSMutableIndexSet indexSet];
		NSArray *items = [spfSession objectForKey:@"contentSelectedIndexSet"];
		NSUInteger i;
		for(i=0; i<[items count]; i++)
			[anIndexSet addIndex:(NSUInteger)NSArrayObjectAtIndex(items, i)];

		[tableContentInstance setSelectedRowIndexesToRestore:anIndexSet];
	}

	// Set table content details for restore
	if([spfSession objectForKey:@"contentSortCol"])
		[tableContentInstance setSortColumnNameToRestore:[spfSession objectForKey:@"contentSortCol"] isAscending:[[spfSession objectForKey:@"contentSortCol"] boolValue]];
	if([spfSession objectForKey:@"contentPageNumber"])
		[tableContentInstance setPageToRestore:[[spfSession objectForKey:@"pageNumber"] integerValue]];
	if([spfSession objectForKey:@"contentViewport"])
		[tableContentInstance setViewportToRestore:NSRectFromString([spfSession objectForKey:@"contentViewport"])];
	if([spfSession objectForKey:@"contentFilter"])
		[tableContentInstance setFiltersToRestore:[spfSession objectForKey:@"contentFilter"]];


	// Select table
	[tablesListInstance selectTableAtIndex:[NSNumber numberWithInteger:[tables indexOfObject:[spfSession objectForKey:@"table"]]]];

	// Reset database view encoding if differs from default
	if([spfSession objectForKey:@"connectionEncoding"] && ![[self connectionEncoding] isEqualToString:[spfSession objectForKey:@"connectionEncoding"]])
		[self setConnectionEncoding:[spfSession objectForKey:@"connectionEncoding"] reloadingViews:YES];

	// Select view
	if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_STRUCTURE"])
		[self viewStructure:self];
	else if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_CONTENT"])
		[self viewContent:self];
	else if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_CUSTOMQUERY"])
		[self viewQuery:self];
	else if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_STATUS"])
		[self viewStatus:self];
	else if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_RELATIONS"])
		[self viewRelations:self];
	else if([[spfSession objectForKey:@"view"] isEqualToString:@"SP_VIEW_TRIGGERS"])
		[self viewTriggers:self];

	[[tablesListInstance valueForKeyPath:@"tablesListView"] scrollRowToVisible:[tables indexOfObject:[spfSession objectForKey:@"selectedTable"]]];

	[tableWindow setTitle:[self displaySPName]];

	// dealloc spfSession data
	[spfSession release];
	spfSession = nil;

	// End the task
	[self endTask];
	[taskPool drain];
}

/**
 * Set the return code for entering the encryption passowrd sheet
 */
- (IBAction)closePasswordSheet:(id)sender
{
	passwordSheetReturnCode = 0;
	if([sender tag]) {
		[NSApp stopModal];
		passwordSheetReturnCode = 1;
	}
	[NSApp abortModal];
}

/**
 * Go backward or forward in the history depending on the menu item selected.
 */
- (IBAction)backForwardInHistory:(id)sender
{
	switch ([sender tag])
	{
		// Go backward
		case 0:
			[spHistoryControllerInstance goBackInHistory];
			break;
		// Go forward
		case 1:
			[spHistoryControllerInstance goForwardInHistory];
			break;
	}
}

#pragma mark -
#pragma mark Connection callback and methods

- (void) setConnection:(MCPConnection *)theConnection
{
	_isConnected = YES;
	mySQLConnection = [theConnection retain];

	// Set the fileURL and init the preferences (query favs, filters, and history) if available for that URL 
	[self setFileURL:[[SPQueryController sharedQueryController] registerDocumentWithFileURL:[self fileURL] andContextInfo:spfPreferences]];
	
	// ...but hide the icon while the document is temporary
	if ([self isUntitled]) [[tableWindow standardWindowButton:NSWindowDocumentIconButton] setImage:nil];

	// Set the connection encoding
	NSString *encodingName = [prefs objectForKey:SPDefaultEncoding];
	if ( [encodingName isEqualToString:@"Autodetect"] ) {
		[self setConnectionEncoding:[self databaseEncoding] reloadingViews:NO];
	} else {
		[self setConnectionEncoding:[self mysqlEncodingFromDisplayEncoding:encodingName] reloadingViews:NO];
	}

	// Get the mysql version
	mySQLVersion = [[NSString alloc] initWithString:[mySQLConnection serverVersionString]];

	// Update the selected database if appropriate
	if ([connectionController database] && ![[connectionController database] isEqualToString:@""]) {
		if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
		selectedDatabase = [[NSString alloc] initWithString:[connectionController database]];
		[spHistoryControllerInstance updateHistoryEntries];
	}

	// Update the database list
	[self setDatabases:self];

	// For each of the main controllers, assign the current connection
	[tablesListInstance setConnection:mySQLConnection];
	[tableSourceInstance setConnection:mySQLConnection];
	[tableContentInstance setConnection:mySQLConnection];
	[tableRelationsInstance setConnection:mySQLConnection];
	[tableTriggersInstance setConnection:mySQLConnection];
	[customQueryInstance setConnection:mySQLConnection];
	[tableDumpInstance setConnection:mySQLConnection];
	[exportControllerInstance setConnection:mySQLConnection];
	[tableDataInstance setConnection:mySQLConnection];
	[extendedTableInfoInstance setConnection:mySQLConnection];
	[databaseDataInstance setConnection:mySQLConnection];
	userManagerInstance.mySqlConnection = mySQLConnection;

	// Set the cutom query editor's MySQL version
	[customQueryInstance setMySQLversion:mySQLVersion];

	[tableWindow setTitle:[self displaySPName]];
	
	// Connected Growl notification
	[[SPGrowlController sharedGrowlController] notifyWithTitle:@"Connected"
												   description:[NSString stringWithFormat:NSLocalizedString(@"Connected to %@",@"description for connected growl notification"), [tableWindow title]]
														window:tableWindow
											  notificationName:@"Connected"];

	// Init Custom Query editor with the stored queries in a spf file if given.
	[spfDocData setObject:[NSNumber numberWithBool:NO] forKey:@"save_editor_content"];
	if(spfSession != nil && [spfSession objectForKey:@"queries"]) {
		[spfDocData setObject:[NSNumber numberWithBool:YES] forKey:@"save_editor_content"];
		if([[spfSession objectForKey:@"queries"] isKindOfClass:[NSData class]]) {
			NSString *q = [[NSString alloc] initWithData:[[spfSession objectForKey:@"queries"] decompress] encoding:NSUTF8StringEncoding];
			[self initQueryEditorWithString:q];
			[q release];
		}
		else
			[self initQueryEditorWithString:[spfSession objectForKey:@"queries"]];
	}

	// Insert queryEditorInitString into the Query Editor if defined
	if(queryEditorInitString && [queryEditorInitString length]) {
		[self viewQuery:self];
		[customQueryInstance doPerformLoadQueryService:queryEditorInitString];
		[queryEditorInitString release];
		queryEditorInitString = nil;
	}

	// Set focus to table list filter field if visible
	// otherwise set focus to Table List view
	if ( [[tablesListInstance tables] count] > 20 )
		[tableWindow makeFirstResponder:listFilterField];
	else
		[tableWindow makeFirstResponder:[tablesListInstance valueForKeyPath:@"tablesListView"]];

	if(spfSession != nil) {

		// Start a task to restore the session details
		[self startTaskWithDescription:NSLocalizedString(@"Restoring session...", @"Restoring session task description")];
		if ([NSThread isMainThread]) {
			[NSThread detachNewThreadSelector:@selector(restoreSession) toTarget:self withObject:nil];
		} else {
			[self restoreSession];
		}
	} else {
		switch ([prefs integerForKey:SPDefaultViewMode] > 0 ? [prefs integerForKey:SPDefaultViewMode] : [prefs integerForKey:SPLastViewMode]) {
			default:
			case SPStructureViewMode:
				[self viewStructure:self];
				break;
			case SPContentViewMode:
				[self viewContent:self];
				break;
			case SPRelationsViewMode:
				[self viewRelations:self];
				break;
			case SPTableInfoViewMode:
				[self viewStatus:self];
				break;
			case SPQueryEditorViewMode:
				[self viewQuery:self];
				break;
			case SPTriggersViewMode:
				[self viewTriggers:self];
				break;
		}
	}

}

/**
 * Set whether the connection controller should automatically start
 * connecting; called by maincontroller, but only for first window.
 */
- (void)setShouldAutomaticallyConnect:(BOOL)shouldAutomaticallyConnect
{
	_shouldOpenConnectionAutomatically = shouldAutomaticallyConnect;
}

/**
 * Allow the connection controller to determine whether connection should
 * be automatically triggered.
 */
- (BOOL)shouldAutomaticallyConnect
{
	return _shouldOpenConnectionAutomatically;
}

/**
 * Sets this connection's Keychain ID.
 */ 
- (void)setKeychainID:(NSString *)theID
{
	keyChainID = [[NSString stringWithString:theID] retain];
}

#pragma mark -
#pragma mark Database methods

/**
 * sets up the database select toolbar item
 */
- (IBAction)setDatabases:(id)sender;
{
	if (!chooseDatabaseButton) return;

	[chooseDatabaseButton removeAllItems];

	[chooseDatabaseButton addItemWithTitle:NSLocalizedString(@"Choose Database...", @"menu item for choose db")];
	[[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];
	[[chooseDatabaseButton menu] addItemWithTitle:NSLocalizedString(@"Add Database...", @"menu item to add db") action:@selector(addDatabase:) keyEquivalent:@""];
	[[chooseDatabaseButton menu] addItemWithTitle:NSLocalizedString(@"Refresh Databases", @"menu item to refresh databases") action:@selector(setDatabases:) keyEquivalent:@""];
	[[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];

	MCPResult *queryResult = [mySQLConnection listDBs];

	if ([queryResult numOfRows]) [queryResult dataSeek:0];

	if (allDatabases) [allDatabases release];
	if (allSystemDatabases) [allSystemDatabases release];
	
	allDatabases = [[NSMutableArray alloc] initWithCapacity:[queryResult numOfRows]];

	allSystemDatabases = [[NSMutableArray alloc] initWithCapacity:2];
	
	for (NSInteger i = 0 ; i < [queryResult numOfRows] ; i++)
	{
		NSString *database = NSArrayObjectAtIndex([queryResult fetchRowAsArray], 0);
		
		// If the database is either information_schema or mysql then it is classed as a system table
		if ([database isEqualToString:@"information_schema"] || [database isEqualToString:@"mysql"]) {
			[allSystemDatabases addObject:database];
		}
		else {
			[allDatabases addObject:database];
		}
	}

	// Add system databases
	for (NSString *db in allSystemDatabases) 
	{
		[chooseDatabaseButton addItemWithTitle:db];
	}
	
	// Add a separator between the system and user databases
	if ([allSystemDatabases count] > 0) {
		[[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];
	}

	// Add user databases
	for (NSString *db in allDatabases) 
	{
		[chooseDatabaseButton addItemWithTitle:db];
	}

	(![self database]) ? [chooseDatabaseButton selectItemAtIndex:0] : [chooseDatabaseButton selectItemWithTitle:[self database]];
	
	
}

/**
 * Selects the database choosen by the user, using a child task if necessary,
 * and displaying errors in an alert sheet on failure.
 */
- (IBAction)chooseDatabase:(id)sender
{
	if (![tablesListInstance selectionShouldChangeInTableView:nil]) {
		[chooseDatabaseButton selectItemWithTitle:[self database]];
		return;
	}

	if ( [chooseDatabaseButton indexOfSelectedItem] == 0 ) {
		if ([self database]) {
			[chooseDatabaseButton selectItemWithTitle:[self database]];
		}
		return;
	}

	// Lock editability again if performing a task
	if (_isWorkingLevel) databaseListIsSelectable = NO;

	// Select the database
	[self selectDatabase:[chooseDatabaseButton titleOfSelectedItem] item:[self table]];

}

/**
 * Select the specified database and, optionally, table.
 */
- (void)selectDatabase:(NSString *)aDatabase item:(NSString *)anItem
{

	// Do not update the navigator since nothing is changed
	[[SPNavigatorController sharedNavigatorController] setIgnoreUpdate:NO];

	// If Navigator runs in syncMode let it follow the selection
	if([[SPNavigatorController sharedNavigatorController] syncMode]) {
		NSMutableString *schemaPath = [NSMutableString string];
		[schemaPath setString:[self connectionID]];
		if([chooseDatabaseButton titleOfSelectedItem] && [[chooseDatabaseButton titleOfSelectedItem] length]) {
			[schemaPath appendString:SPUniqueSchemaDelimiter];
			[schemaPath appendString:[chooseDatabaseButton titleOfSelectedItem]];
		}
		[[SPNavigatorController sharedNavigatorController] selectPath:schemaPath];
	}

	// Start a task
	[self startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Loading database '%@'...", @"Loading database task string"), [chooseDatabaseButton titleOfSelectedItem]]];
	NSDictionary *selectionDetails = [NSDictionary dictionaryWithObjectsAndKeys:
										aDatabase, @"database",
										anItem, @"item",
										nil];
	if ([NSThread isMainThread]) {
		[NSThread detachNewThreadSelector:@selector(_selectDatabaseAndItem:) toTarget:self withObject:selectionDetails];
	} else {
		[self _selectDatabaseAndItem:selectionDetails];
	}

}

/**
 * opens the add-db sheet and creates the new db
 */
- (IBAction)addDatabase:(id)sender
{
	if (![tablesListInstance selectionShouldChangeInTableView:nil]) return;

	[databaseNameField setStringValue:@""];

	[NSApp beginSheet:databaseSheet
	   modalForWindow:tableWindow
		modalDelegate:self
	   didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:)
		  contextInfo:@"addDatabase"];
}

/**
 * opens sheet to ask user if he really wants to delete the db
 */
- (IBAction)removeDatabase:(id)sender
{
	// No database selected, bail
	if ([chooseDatabaseButton indexOfSelectedItem] == 0) return;

	if (![tablesListInstance selectionShouldChangeInTableView:nil]) return;

	NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Delete database '%@'?", @"delete database message"), [self database]]
									 defaultButton:NSLocalizedString(@"Delete", @"delete button") 
								   alternateButton:NSLocalizedString(@"Cancel", @"cancel button") 
									  otherButton:nil 
						informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the database '%@'? This operation cannot be undone.", @"delete database informative message"), [self database]]];

	NSArray *buttons = [alert buttons];

	// Change the alert's cancel button to have the key equivalent of return
	[[buttons objectAtIndex:0] setKeyEquivalent:@"d"];
	[[buttons objectAtIndex:0] setKeyEquivalentModifierMask:NSCommandKeyMask];
	[[buttons objectAtIndex:1] setKeyEquivalent:@"\r"];

	[alert setAlertStyle:NSCriticalAlertStyle];

	[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"removeDatabase"];
}

/**
 * Displays the database server variables sheet.
 */
- (IBAction)showServerVariables:(id)sender
{
	if (!serverVariablesController) {
		serverVariablesController = [[SPServerVariablesController alloc] init];
		
		[serverVariablesController setConnection:mySQLConnection];
		
		// Register to obeserve table view vertical grid line pref changes
		[prefs addObserver:serverVariablesController forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	}
	
	[serverVariablesController displayServerVariablesSheetAttachedToWindow:tableWindow];
}

/**
 * Displays the database process list sheet.
 */
- (IBAction)showServerProcesses:(id)sender
{
	if (!processListController) {
		processListController = [[SPProcessListController alloc] init];
		
		[processListController setConnection:mySQLConnection];
		
		// Register to obeserve table view vertical grid line pref changes
		[prefs addObserver:processListController forKeyPath:SPDisplayTableViewVerticalGridlines options:NSKeyValueObservingOptionNew context:NULL];
	}
	
	[processListController displayProcessListWindow];
}

/**
 * Returns an array of all available database names
 */
- (NSArray *)allDatabaseNames
{
	return allDatabases;
}

/**
 * Returns an array of all available system database names
 */
- (NSArray *)allSystemDatabaseNames
{
	return allSystemDatabases;
}

/**
 * Alert sheet method. Invoked when an alert sheet is dismissed.
 *
 * if contextInfo == removeDatabase -> Remove the selected database
 * if contextInfo == addDatabase    -> Add a new database
 */
- (void)sheetDidEnd:(id)sheet returnCode:(NSInteger)returnCode contextInfo:(NSString *)contextInfo
{

	// Order out current sheet to suppress overlapping of sheets
	if ([sheet respondsToSelector:@selector(orderOut:)])
		[sheet orderOut:nil];
	else if ([sheet respondsToSelector:@selector(window)])
		[[sheet window] orderOut:nil];

	// Remove the current database
	if ([contextInfo isEqualToString:@"removeDatabase"]) {
		if (returnCode == NSAlertDefaultReturn) {
			[self _removeDatabase];
		}
	}
	// Add a new database
	else if ([contextInfo isEqualToString:@"addDatabase"]) {
		if (returnCode == NSOKButton) {
			[self _addDatabase];

			// Query the structure of all databases in the background (mainly for completion)
			[NSThread detachNewThreadSelector:@selector(queryDbStructureWithUserInfo:) toTarget:mySQLConnection withObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], @"forceUpdate", nil]];

		} else {
			// reset chooseDatabaseButton
			if([[self database] length])
				[chooseDatabaseButton selectItemWithTitle:[self database]];
			else
				[chooseDatabaseButton selectItemAtIndex:0];
		}
	}
	// Close error status sheet for OPTIMIZE, CHECK, REPAIR etc.
	else if ([contextInfo isEqualToString:@"statusError"]) {
		if (statusValues) [statusValues release], statusValues = nil;
	}

}

/**
 * Show Error sheet (can be called from inside of a endSheet selector)
 * via [self performSelector:@selector(showErrorSheetWithTitle:) withObject: afterDelay:]
 */
-(void)showErrorSheetWith:(id)error
{
	// error := first object is the title , second the message, only one button OK
	SPBeginAlertSheet([error objectAtIndex:0], NSLocalizedString(@"OK", @"OK button"), 
			nil, nil, tableWindow, self, nil, nil, nil,
			[error objectAtIndex:1]);
}

/**
 * Reset the current selected database name
 */
- (void)refreshCurrentDatabase
{
	NSString *dbName = nil;

	// Notify listeners that a query has started
	[[NSNotificationCenter defaultCenter] postNotificationName:@"SMySQLQueryWillBePerformed" object:self];

	MCPResult *theResult = [mySQLConnection queryString:@"SELECT DATABASE()"];
	if (![mySQLConnection queryErrored]) {
		NSInteger i;
		NSInteger r = [theResult numOfRows];
		if (r) [theResult dataSeek:0];
		for ( i = 0 ; i < r ; i++ ) {
			dbName = NSArrayObjectAtIndex([theResult fetchRowAsArray], 0);
		}
		if(![dbName isKindOfClass:[NSNull class]]) {
			if(![dbName isEqualToString:selectedDatabase]) {
				if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
				selectedDatabase = [[NSString alloc] initWithString:dbName];
				[chooseDatabaseButton selectItemWithTitle:selectedDatabase];
				[tableWindow setTitle:[self displaySPName]];
			}
		} else {
			if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
			[chooseDatabaseButton selectItemAtIndex:0];
			[tableWindow setTitle:[self displaySPName]];
		}
	}

	//query finished
	[[NSNotificationCenter defaultCenter] postNotificationName:@"SMySQLQueryHasBeenPerformed" object:self];
}

- (BOOL)navigatorSchemaPathExistsForDatabase:(NSString*)dbname
{
	return [[SPNavigatorController sharedNavigatorController] schemaPathExistsForConnection:[self connectionID] andDatabase:dbname];
}

- (NSDictionary*)getDbStructure
{
	return [[SPNavigatorController sharedNavigatorController] dbStructureForConnection:[self connectionID]];
}

- (NSArray *)allSchemaKeys
{
	return [[SPNavigatorController sharedNavigatorController] allSchemaKeysForConnection:[self connectionID]];
}

#pragma mark -
#pragma mark Console methods

/**
 * Shows or hides the console
 */
- (void)toggleConsole:(id)sender
{
	BOOL isConsoleVisible = [[[SPQueryController sharedQueryController] window] isVisible];

	// If the Console window is not visible data are not reloaded (for speed).
	// Due to that update list if user opens the Console window.
	if(!isConsoleVisible) {
		[[SPQueryController sharedQueryController] updateEntries];
	}

	// Show or hide the console
	[[[SPQueryController sharedQueryController] window] setIsVisible:(!isConsoleVisible)];
}

/**
 * Brings the console to the fron
 */
- (void)showConsole:(id)sender
{
	BOOL isConsoleVisible = [[[SPQueryController sharedQueryController] window] isVisible];

	if (!isConsoleVisible) {
		[self toggleConsole:sender];
	} else {
		[[[SPQueryController sharedQueryController] window] makeKeyAndOrderFront:self];
	}

}

/**
 * Clears the console by removing all of its messages
 */
- (void)clearConsole:(id)sender
{
	[[SPQueryController sharedQueryController] clearConsole:sender];
}

/**
 * Set a query mode, used to control logging dependant on preferences
 */
- (void) setQueryMode:(NSInteger)theQueryMode
{
	_queryMode = theQueryMode;
}

#pragma mark -
#pragma mark Navigator methods

/**
 * Shows or hides the navigator
 */
- (IBAction)toggleNavigator:(id)sender
{
	BOOL isNavigatorVisible = [[[SPNavigatorController sharedNavigatorController] window] isVisible];

	if(!isNavigatorVisible) {
		[[SPNavigatorController sharedNavigatorController] updateEntriesForConnection:[self connectionID]];
	}

	// Show or hide the navigator
	[[[SPNavigatorController sharedNavigatorController] window] setIsVisible:(!isNavigatorVisible)];
}

- (IBAction)showNavigator:(id)sender
{
	BOOL isNavigatorVisible = [[[SPNavigatorController sharedNavigatorController] window] isVisible];
	
	if (!isNavigatorVisible) {
		[self toggleNavigator:sender];
	} else {
		[[[SPNavigatorController sharedNavigatorController] window] makeKeyAndOrderFront:self];
	}
}

#pragma mark -
#pragma mark Task progress and notification methods

/**
 * Start a document-wide task, providing a short task description for
 * display to the user.  This sets the document into working mode,
 * preventing many actions, and shows an indeterminate progress interface
 * to the user.
 */
- (void) startTaskWithDescription:(NSString *)description
{

	// Set the task text.  If a nil string was supplied, a generic query notification is occurring -
	// if a task is not already active, use default text.
	if (!description) {
		if (!_isWorkingLevel) [taskDescriptionText setStringValue:NSLocalizedString(@"Working...", @"Generic working description")];
	
	// Otherwise display the supplied string
	} else {
		[taskDescriptionText setStringValue:description];
	}

	// Increment the task level
	_isWorkingLevel++;

	// Reset the progress indicator if necessary
	if (_isWorkingLevel == 1 || !taskDisplayIsIndeterminate) {
		taskDisplayIsIndeterminate = YES;
		[taskProgressIndicator setIndeterminate:YES];
		[taskProgressIndicator animate:self];
		[taskProgressIndicator startAnimation:self];
		taskDisplayLastValue = 0;
	}

	// If the working level just moved to start a task, set up the interface
	if (_isWorkingLevel == 1) {
		[taskCancelButton setHidden:YES];

		// Set flags and prevent further UI interaction in this window
		[historyControl setEnabled:NO];
		databaseListIsSelectable = NO;
		[[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentTaskStartNotification object:self];
		[mainToolbar validateVisibleItems];
				
		// Schedule appearance of the task window in the near future
		taskDrawTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(showTaskProgressWindow:) userInfo:nil repeats:NO] retain];
	}
}

/**
 * Show the task progress window, after a small delay to minimise flicker.
 */
- (void) showTaskProgressWindow:(NSTimer *)theTimer
{
	if (taskDrawTimer) [taskDrawTimer invalidate], [taskDrawTimer release], taskDrawTimer = nil;

	// Center the task window and fade it in
	[self centerTaskWindow];
	NSDictionary *animationDetails = [NSDictionary dictionaryWithObjectsAndKeys:
										NSViewAnimationFadeInEffect, NSViewAnimationEffectKey,
										taskProgressWindow, NSViewAnimationTargetKey,
										nil];
	taskFadeAnimator = [[NSViewAnimation alloc] initWithViewAnimations:[NSArray arrayWithObject:animationDetails]];
	[taskFadeAnimator setDuration:0.6];
	[taskFadeAnimator startAnimation];
}


/**
 * Updates the task description shown to the user.
 */
- (void) setTaskDescription:(NSString *)description
{
	[taskDescriptionText setStringValue:description];
}

/**
 * Sets the task percentage progress - the first call to this automatically
 * switches the progress display to determinate.
 */
- (void) setTaskPercentage:(CGFloat)taskPercentage
{
	if (taskDisplayIsIndeterminate) {
		taskDisplayIsIndeterminate = NO;
		[taskProgressIndicator stopAnimation:self];
		[taskProgressIndicator setDoubleValue:0.5];
	}

	taskProgressValue = taskPercentage;
	if (taskProgressValue > taskDisplayLastValue + taskProgressValueDisplayInterval
		|| taskProgressValue < taskDisplayLastValue - taskProgressValueDisplayInterval)
	{
		[taskProgressIndicator setDoubleValue:taskProgressValue];
		taskDisplayLastValue = taskProgressValue;
	}
}

/**
 * Sets the task progress indicator back to indeterminate (also performed
 * automatically whenever a new task is started).
 * This can optionally be called with afterDelay set, in which case the intederminate
 * switch will be made a fter a short pause to minimise flicker for short actions.
 */
- (void) setTaskProgressToIndeterminateAfterDelay:(BOOL)afterDelay
{
	if (afterDelay) {
		[self performSelector:@selector(setTaskProgressToIndeterminateAfterDelay:) withObject:nil afterDelay:0.5];
		return;
	}

	if (taskDisplayIsIndeterminate) return;
	taskDisplayIsIndeterminate = YES;
	[taskProgressIndicator setIndeterminate:YES];
	[taskProgressIndicator startAnimation:self];
	taskDisplayLastValue = 0;
}

/**
 * Hide the task progress and restore the document to allow actions again.
 */
- (void) endTask
{

	// Ensure a call on the main thread
	if (![NSThread isMainThread]) {
		[self performSelectorOnMainThread:@selector(endTask) withObject:nil waitUntilDone:YES];
		return;
	}

	// Decrement the working level
	_isWorkingLevel--;

	// Ensure cancellation interface is reset
	[self disableTaskCancellation];

	// If all tasks have ended, re-enable the interface
	if (!_isWorkingLevel) {

		// Cancel the draw timer if it exists
		if (taskDrawTimer) [taskDrawTimer invalidate], [taskDrawTimer release], taskDrawTimer = nil;

		// Cancel the fade-in animator if it exists
		if (taskFadeAnimator) {
			if ([taskFadeAnimator isAnimating]) [taskFadeAnimator stopAnimation];
			[taskFadeAnimator release], taskFadeAnimator = nil;
		}

		// Hide the task interface and reset to indeterminate
		if (taskDisplayIsIndeterminate) [taskProgressIndicator stopAnimation:self];
		[taskProgressWindow setAlphaValue:0.0];
		taskDisplayIsIndeterminate = YES;
		[taskProgressIndicator setIndeterminate:YES];

		// Re-enable window interface
		[historyControl setEnabled:YES];
		databaseListIsSelectable = YES;
		[[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentTaskEndNotification object:self];
		[mainToolbar validateVisibleItems];
	}
}

/**
 * Allow a task to be cancelled, enabling the button with a supplied title
 * and optionally supplying a callback object and function.
 */
- (void) enableTaskCancellationWithTitle:(NSString *)buttonTitle callbackObject:(id)callbackObject callbackFunction:(SEL)callbackFunction
{

	// If no task is active, return
	if (!_isWorkingLevel) return;

	if (callbackObject && callbackFunction) {
		taskCancellationCallbackObject = callbackObject;
		taskCancellationCallbackSelector = callbackFunction;
	}
	taskCanBeCancelled = YES;

	[taskCancelButton setTitle:buttonTitle];
	[taskCancelButton setEnabled:YES];
	[taskCancelButton setHidden:NO];
}

/**
 * Disable task cancellation.  Called automatically at the end of a task.
 */
- (void) disableTaskCancellation
{

	// If no task is active, return
	if (!_isWorkingLevel) return;
	
	taskCanBeCancelled = NO;
	taskCancellationCallbackObject = nil;
	taskCancellationCallbackSelector = NULL;
	[taskCancelButton setHidden:YES];
}

/**
 * Action sent by the cancel button when it's active.
 */
- (IBAction) cancelTask:(id)sender
{
	if (!taskCanBeCancelled) return;

	[taskCancelButton setEnabled:NO];
	[mySQLConnection cancelCurrentQuery];

	if (taskCancellationCallbackObject && taskCancellationCallbackSelector) {
		[taskCancellationCallbackObject performSelector:taskCancellationCallbackSelector];
	}
}

/**
 * Returns whether the document is busy performing a task - allows UI or actions
 * to be restricted as appropriate.
 */
- (BOOL) isWorking
{
	return (_isWorkingLevel > 0);
}

/**
 * Set whether the database list is selectable or not during the task process.
 */
- (void) setDatabaseListIsSelectable:(BOOL)isSelectable
{
	databaseListIsSelectable = isSelectable;
}

/**
 * Reposition the task window within the main window.
 */
- (void) centerTaskWindow
{
	NSPoint newBottomLeftPoint;
	NSRect mainWindowRect = [tableWindow frame];
	NSRect taskWindowRect = [taskProgressWindow frame];

	newBottomLeftPoint.x = round(mainWindowRect.origin.x + mainWindowRect.size.width/2 - taskWindowRect.size.width/2);
	newBottomLeftPoint.y = round(mainWindowRect.origin.y + mainWindowRect.size.height/2 - taskWindowRect.size.height/2);

	[taskProgressWindow setFrameOrigin:newBottomLeftPoint];
}

#pragma mark -
#pragma mark Encoding Methods

/**
 * Set the encoding for the database connection
 */
- (void)setConnectionEncoding:(NSString *)mysqlEncoding reloadingViews:(BOOL)reloadViews
{
	_encodingViaLatin1 = NO;

	// Special-case UTF-8 over latin 1 to allow viewing/editing of mangled data.
	if ([mysqlEncoding isEqualToString:@"utf8-"]) {
		_encodingViaLatin1 = YES;
		mysqlEncoding = @"utf8";
	}

	// set encoding of connection and client
	[mySQLConnection queryString:[NSString stringWithFormat:@"SET NAMES '%@'", mysqlEncoding]];

	if (![mySQLConnection queryErrored]) {
		if (_encodingViaLatin1)
			[mySQLConnection queryString:@"SET CHARACTER_SET_RESULTS=latin1"];
		[mySQLConnection setEncoding:[MCPConnection encodingForMySQLEncoding:[mysqlEncoding UTF8String]]];
		[_encoding release];
		_encoding = [[NSString alloc] initWithString:mysqlEncoding];
	} else {
		[mySQLConnection queryString:[NSString stringWithFormat:@"SET NAMES '%@'", [self databaseEncoding]]];
		_encodingViaLatin1 = NO;
		if ([mySQLConnection queryErrored]) {
			NSLog(@"Error: could not set encoding to %@ nor fall back to database encoding on MySQL %@", mysqlEncoding, [self mySQLVersion]);
			return;
		}
	}

	// update the selected menu item
	if (_encodingViaLatin1) {
		[self updateEncodingMenuWithSelectedEncoding:[self encodingNameFromMySQLEncoding:[NSString stringWithFormat:@"%@-", mysqlEncoding]]];
	} else {
		[self updateEncodingMenuWithSelectedEncoding:[self encodingNameFromMySQLEncoding:mysqlEncoding]];
	}

	// Reload stuff as appropriate
	[tableDataInstance resetAllData];
	if (reloadViews) {
		if ([tablesListInstance structureLoaded]) [tableSourceInstance reloadTable:self];
		if ([tablesListInstance contentLoaded]) [tableContentInstance reloadTable:self];
		if ([tablesListInstance statusLoaded]) [extendedTableInfoInstance reloadTable:self];
	}
}

/**
 * returns the current mysql encoding for this object
 */
- (NSString *)connectionEncoding
{
	return _encoding;
}

/**
 * Returns whether the current encoding should display results via Latin1 transport for backwards compatibility.
 * This is a delegate method of MCPKit's MCPConnection class.
 */
- (BOOL)connectionEncodingViaLatin1:(id)connection
{
	return _encodingViaLatin1;
}

/**
 * updates the currently selected item in the encoding menu
 * 
 * @param NSString *encoding - the title of the menu item which will be selected
 */
- (void)updateEncodingMenuWithSelectedEncoding:(NSString *)encoding
{
	NSEnumerator *dbEncodingMenuEn = [[selectEncodingMenu itemArray] objectEnumerator];
	id menuItem;
	NSInteger correctStateForMenuItem;
	while (menuItem = [dbEncodingMenuEn nextObject]) {
		correctStateForMenuItem = [[menuItem title] isEqualToString:encoding] ? NSOnState : NSOffState;

		if ([menuItem state] == correctStateForMenuItem) // don't re-apply state incase it causes performance issues
			continue;

		[menuItem setState:correctStateForMenuItem];
	}
}

/**
 * Returns the display name for a mysql encoding
 */
- (NSString *)encodingNameFromMySQLEncoding:(NSString *)mysqlEncoding
{
	NSDictionary *translationMap = [NSDictionary dictionaryWithObjectsAndKeys:
									@"UCS-2 Unicode (ucs2)", @"ucs2",
									@"UTF-8 Unicode (utf8)", @"utf8",
									@"UTF-8 Unicode via Latin 1", @"utf8-",
									@"US ASCII (ascii)", @"ascii",
									@"ISO Latin 1 (latin1)", @"latin1",
									@"Mac Roman (macroman)", @"macroman",
									@"Windows Latin 2 (cp1250)", @"cp1250",
									@"ISO Latin 2 (latin2)", @"latin2",
									@"Windows Arabic (cp1256)", @"cp1256",
									@"ISO Greek (greek)", @"greek",
									@"ISO Hebrew (hebrew)", @"hebrew",
									@"ISO Turkish (latin5)", @"latin5",
									@"Windows Baltic (cp1257)", @"cp1257",
									@"Windows Cyrillic (cp1251)", @"cp1251",
									@"Big5 Traditional Chinese (big5)", @"big5",
									@"Shift-JIS Japanese (sjis)", @"sjis",
									@"EUC-JP Japanese (ujis)", @"ujis",
									@"EUC-KR Korean (euckr)", @"euckr",
									nil];
	NSString *encodingName = [translationMap valueForKey:mysqlEncoding];

	if (!encodingName)
		return [NSString stringWithFormat:@"Unknown Encoding (%@)", mysqlEncoding, nil];

	return encodingName;
}

/**
 * Returns the mysql encoding for an encoding string that is displayed to the user
 */
- (NSString *)mysqlEncodingFromDisplayEncoding:(NSString *)encodingName
{
	NSDictionary *translationMap = [NSDictionary dictionaryWithObjectsAndKeys:
									@"ucs2", @"UCS-2 Unicode (ucs2)",
									@"utf8", @"UTF-8 Unicode (utf8)",
									@"utf8-", @"UTF-8 Unicode via Latin 1",
									@"ascii", @"US ASCII (ascii)",
									@"latin1", @"ISO Latin 1 (latin1)",
									@"macroman", @"Mac Roman (macroman)",
									@"cp1250", @"Windows Latin 2 (cp1250)",
									@"latin2", @"ISO Latin 2 (latin2)",
									@"cp1256", @"Windows Arabic (cp1256)",
									@"greek", @"ISO Greek (greek)",
									@"hebrew", @"ISO Hebrew (hebrew)",
									@"latin5", @"ISO Turkish (latin5)",
									@"cp1257", @"Windows Baltic (cp1257)",
									@"cp1251", @"Windows Cyrillic (cp1251)",
									@"big5", @"Big5 Traditional Chinese (big5)",
									@"sjis", @"Shift-JIS Japanese (sjis)",
									@"ujis", @"EUC-JP Japanese (ujis)",
									@"euckr", @"EUC-KR Korean (euckr)",
									nil];
	NSString *mysqlEncoding = [translationMap valueForKey:encodingName];

	if (!mysqlEncoding)
		return @"utf8";

	return mysqlEncoding;
}

/**
 * Detect and return the database connection encoding.
 * TODO: See http://code.google.com/p/sequel-pro/issues/detail?id=134 - some question over why this [historically] uses _connection not _database...
 */
- (NSString *)databaseEncoding
{
	MCPResult *charSetResult;
	NSString *mysqlEncoding;

	// MySQL > 4.0
	charSetResult = [mySQLConnection queryString:@"SHOW VARIABLES LIKE 'character_set_connection'"];
	[charSetResult setReturnDataAsStrings:YES];
	mysqlEncoding = [[charSetResult fetchRowAsDictionary] objectForKey:@"Value"];
	_supportsEncoding = (mysqlEncoding != nil);

	// mysql 4.0 or older -> only default character set possible, cannot choose others using "set names xy"
	if ( !mysqlEncoding ) {
		mysqlEncoding = [[[mySQLConnection queryString:@"SHOW VARIABLES LIKE 'character_set'"] fetchRowAsDictionary] objectForKey:@"Value"];
	}

	// older version? -> set encoding to mysql default encoding latin1
	if ( !mysqlEncoding ) {
		NSLog(@"Error: no character encoding found, mysql version is %@", [self mySQLVersion]);
		mysqlEncoding = @"latin1";
	}

	return mysqlEncoding;
}

/**
 * When sent by an NSMenuItem, will set the encoding based on the title of the menu item
 */
- (IBAction)chooseEncoding:(id)sender
{
	[self setConnectionEncoding:[self mysqlEncodingFromDisplayEncoding:[(NSMenuItem *)sender title]] reloadingViews:YES];
}

/**
 * return YES if MySQL server supports choosing connection and table encodings (MySQL 4.1 and newer)
 */
- (BOOL)supportsEncoding
{
	return _supportsEncoding;
}

#pragma mark -
#pragma mark Table Methods

/**
 * Displays the CREATE TABLE syntax of the selected table to the user via a HUD panel.
 */
- (IBAction)showCreateTableSyntax:(id)sender
{
	//Create the query and get results
	NSInteger colOffs = 1;
	NSString *query = nil;
	NSString *typeString = @"";

	if( [tablesListInstance tableType] == SPTableTypeTable ) {
		query = [NSString stringWithFormat:@"SHOW CREATE TABLE %@", [[self table] backtickQuotedString]];
		typeString = @"table";
	}
	else if( [tablesListInstance tableType] == SPTableTypeView ) {
		query = [NSString stringWithFormat:@"SHOW CREATE VIEW %@", [[self table] backtickQuotedString]];
		typeString = @"view";
	}
	else if( [tablesListInstance tableType] == SPTableTypeProc ) {
		query = [NSString stringWithFormat:@"SHOW CREATE PROCEDURE %@", [[self table] backtickQuotedString]];
		typeString = @"procedure";
		colOffs = 2;
	}
	else if( [tablesListInstance tableType] == SPTableTypeFunc ) {
		query = [NSString stringWithFormat:@"SHOW CREATE FUNCTION %@", [[self table] backtickQuotedString]];
		typeString = @"function";
		colOffs = 2;
	}

	if (query == nil) return;

	MCPResult *theResult = [mySQLConnection queryString:query];
	[theResult setReturnDataAsStrings:YES];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		if ([mySQLConnection isConnected]) {
			NSRunAlertPanel(@"Error", [NSString stringWithFormat:@"An error occured while creating table syntax.\n\n: %@",[mySQLConnection getLastErrorMessage]], @"OK", nil, nil);
		}

		return;
	}

	NSString *tableSyntax = [[theResult fetchRowAsArray] objectAtIndex:colOffs];

	// A NULL value indicates that the user does not have permission to view the syntax
	if ([tableSyntax isNSNull]) {
		[[NSAlert alertWithMessageText:NSLocalizedString(@"Permission Denied", @"Permission Denied")
						 defaultButton:NSLocalizedString(@"OK", @"OK")
					   alternateButton:nil otherButton:nil
			 informativeTextWithFormat:NSLocalizedString(@"The creation syntax could not be retrieved due to a permissions error.\n\nPlease check your user permissions with an administrator.", @"Create syntax permission denied detail")]
			  beginSheetModalForWindow:tableWindow
						 modalDelegate:self didEndSelector:NULL contextInfo:NULL];
		return;
	}

	[createTableSyntaxTextField setStringValue:[NSString stringWithFormat:@"Create syntax for %@ '%@'", typeString, [self table]]];

	[createTableSyntaxTextView setEditable:YES];
	[createTableSyntaxTextView setString:@""];
	[createTableSyntaxTextView insertText:([tablesListInstance tableType] == SPTableTypeView) ? [tableSyntax createViewSyntaxPrettifier] : tableSyntax];
	[createTableSyntaxTextView setEditable:NO];

	[createTableSyntaxWindow makeFirstResponder:createTableSyntaxTextField];

	// Show variables sheet
	[NSApp beginSheet:createTableSyntaxWindow
	   modalForWindow:tableWindow 
		modalDelegate:self
	   didEndSelector:nil 
		  contextInfo:nil];

}

/**
 * Copies the CREATE TABLE syntax of the selected table to the pasteboard.
 */
- (IBAction)copyCreateTableSyntax:(id)sender
{
	// Create the query and get results
	NSString *query = nil;
	NSInteger colOffs = 1;

	if( [tablesListInstance tableType] == SPTableTypeTable ) {
		query = [NSString stringWithFormat:@"SHOW CREATE TABLE %@", [[self table] backtickQuotedString]];
	}
	else if( [tablesListInstance tableType] == SPTableTypeView ) {
		query = [NSString stringWithFormat:@"SHOW CREATE VIEW %@", [[self table] backtickQuotedString]];
	}
	else if( [tablesListInstance tableType] == SPTableTypeProc ) {
		query = [NSString stringWithFormat:@"SHOW CREATE PROCEDURE %@", [[self table] backtickQuotedString]];
		colOffs = 2;
	}
	else if( [tablesListInstance tableType] == SPTableTypeFunc ) {
		query = [NSString stringWithFormat:@"SHOW CREATE FUNCTION %@", [[self table] backtickQuotedString]];
		colOffs = 2;
	}

	if( query == nil )
		return;

	MCPResult *theResult = [mySQLConnection queryString:query];
	[theResult setReturnDataAsStrings:YES];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		if ([mySQLConnection isConnected]) {
			NSRunAlertPanel(@"Error", [NSString stringWithFormat:@"An error occured while creating table syntax.\n\n: %@",[mySQLConnection getLastErrorMessage]], @"OK", nil, nil);
		}
		return;
	}

	NSString *tableSyntax = [[theResult fetchRowAsArray] objectAtIndex:colOffs];

	// A NULL value indicates that the user does not have permission to view the syntax
	if ([tableSyntax isNSNull]) {
		[[NSAlert alertWithMessageText:NSLocalizedString(@"Permission Denied", @"Permission Denied")
						 defaultButton:NSLocalizedString(@"OK", @"OK")
					   alternateButton:nil otherButton:nil
			 informativeTextWithFormat:NSLocalizedString(@"The creation syntax could not be retrieved due to a permissions error.\n\nPlease check your user permissions with an administrator.", @"Create syntax permission denied detail")]
			  beginSheetModalForWindow:tableWindow
						 modalDelegate:self didEndSelector:NULL contextInfo:NULL];
		return;
	}

	// copy to the clipboard
	NSPasteboard *pb = [NSPasteboard generalPasteboard];
	[pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:self];
	if([tablesListInstance tableType] == SPTableTypeView)
		[pb setString:[tableSyntax createViewSyntaxPrettifier] forType:NSStringPboardType];
	else
		[pb setString:tableSyntax forType:NSStringPboardType];

	// Table syntax copied Growl notification
	[[SPGrowlController sharedGrowlController] notifyWithTitle:@"Syntax Copied"
												   description:[NSString stringWithFormat:NSLocalizedString(@"Syntax for %@ table copied",@"description for table syntax copied growl notification"), [self table]] 
														window:tableWindow
											  notificationName:@"Syntax Copied"];
}

/**
 * Performs a MySQL check table on the selected table and presents the result to the user via an alert sheet.
 */
- (IBAction)checkTable:(id)sender
{

	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;
	
	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"CHECK TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to check selected items", @"unable to check selected items message") : NSLocalizedString(@"Unable to check table", @"unable to check table message");
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:mText 
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to check the %@.\n\nMySQL said:%@",@"an error occurred while trying to check the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
	BOOL statusOK = YES;
	for(id res in result) {
		if(![[res objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
			statusOK = NO;
			break;
		}
	}

	// Process result
	if([selectedItems count] == 1) {
		NSDictionary *lastresult = [[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject];

		message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Check table successfully passed.",@"check table successfully passed message") : NSLocalizedString(@"Check table failed.", @"check table failed message");

		message = [NSString stringWithFormat:@"%@\n\nMySQL said: %@", message, [lastresult objectForKey:@"Msg_text"]];
	} else if(statusOK) {
		message = NSLocalizedString(@"Check of all selected items successfully passed.",@"check of all selected items successfully passed message");
	}
	
	if(message) {
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Check %@", what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:message] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		message = NSLocalizedString(@"MySQL said:",@"mysql said message");
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:message];
		[alert setMessageText:NSLocalizedString(@"Error while checking selected items", @"error while checking selected items message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Analyzes the selected table and presents the result to the user via an alert sheet.
 */
- (IBAction)analyzeTable:(id)sender
{

	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;
	
	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"ANALYZE TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to analyze selected items", @"unable to analyze selected items message") : NSLocalizedString(@"Unable to analyze table", @"unable to analyze table message");
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:mText 
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while analyzing the %@.\n\nMySQL said:%@",@"an error occurred while analyzing the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
	BOOL statusOK = YES;
	for(id res in result) {
		if(![[res objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
			statusOK = NO;
			break;
		}
	}

	// Process result
	if([selectedItems count] == 1) {
		NSDictionary *lastresult = [[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject];

		message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully analyzed table.",@"analyze table successfully passed message") : NSLocalizedString(@"Analyze table failed.", @"analyze table failed message");

		message = [NSString stringWithFormat:@"%@\n\nMySQL said: %@", message, [lastresult objectForKey:@"Msg_text"]];
	} else if(statusOK) {
		message = NSLocalizedString(@"Successfully analyzed all selected items.",@"successfully analyzed all selected items message");
	}
	
	if(message) {
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Analyze %@", what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:message] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		message = NSLocalizedString(@"MySQL said:",@"mysql said message");
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:message];
		[alert setMessageText:NSLocalizedString(@"Error while analyzing selected items", @"error while analyzing selected items message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Optimizes the selected table and presents the result to the user via an alert sheet.
 */
- (IBAction)optimizeTable:(id)sender
{

	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;

	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"OPTIMIZE TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to optimze selected items", @"unable to optimze selected items message") : NSLocalizedString(@"Unable to optimze table", @"unable to optimze table message");
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:mText 
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while optimzing the %@.\n\nMySQL said:%@",@"an error occurred while trying to optimze the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
	BOOL statusOK = YES;
	for(id res in result) {
		if(![[res objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
			statusOK = NO;
			break;
		}
	}

	// Process result
	if([selectedItems count] == 1) {
		NSDictionary *lastresult = [[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject];

		message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully optimized table.",@"optimize table successfully passed message") : NSLocalizedString(@"Optimize table failed.", @"optimize table failed message");

		message = [NSString stringWithFormat:@"%@\n\nMySQL said: %@", message, [lastresult objectForKey:@"Msg_text"]];
	} else if(statusOK) {
		message = NSLocalizedString(@"Successfully optimized all selected items.",@"successfully optimized all selected items message");
	}

	if(message) {
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Optimize %@", what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:message] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		message = NSLocalizedString(@"MySQL said:",@"mysql said message");
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:message];
		[alert setMessageText:NSLocalizedString(@"Error while optimizing selected items", @"error while optimizing selected items message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Repairs the selected table and presents the result to the user via an alert sheet.
 */
- (IBAction)repairTable:(id)sender
{
	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;

	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"REPAIR TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to repair selected items", @"unable to repair selected items message") : NSLocalizedString(@"Unable to repair table", @"unable to repair table message");
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:mText 
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while repairing the %@.\n\nMySQL said:%@",@"an error occurred while trying to repair the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
	BOOL statusOK = YES;
	for(id res in result) {
		if(![[res objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
			statusOK = NO;
			break;
		}
	}

	// Process result
	if([selectedItems count] == 1) {
		NSDictionary *lastresult = [[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject];

		message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully repaired table.",@"repair table successfully passed message") : NSLocalizedString(@"Repair table failed.", @"repair table failed message");

		message = [NSString stringWithFormat:@"%@\n\nMySQL said: %@", message, [lastresult objectForKey:@"Msg_text"]];
	} else if(statusOK) {
		message = NSLocalizedString(@"Successfully repaired all selected items.",@"successfully repaired all selected items message");
	}

	if(message) {
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Repair %@", what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:message] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		message = NSLocalizedString(@"MySQL said:",@"mysql said message");
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:message];
		[alert setMessageText:NSLocalizedString(@"Error while repairing selected items", @"error while repairing selected items message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Flush the selected table and inform the user via a dialog sheet.
 */
- (IBAction)flushTable:(id)sender
{
	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;

	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"FLUSH TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		NSString *mText = ([selectedItems count]>1) ? NSLocalizedString(@"Unable to flush selected items", @"unable to flush selected items message") : NSLocalizedString(@"Unable to flush table", @"unable to flush table message");
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:mText 
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while flushing the %@.\n\nMySQL said:%@",@"an error occurred while trying to flush the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
	BOOL statusOK = YES;
	for(id res in result) {
		if(![[res objectForKey:@"Msg_type"] isEqualToString:@"status"]) {
			statusOK = NO;
			break;
		}
	}

	// Process result
	if([selectedItems count] == 1) {
		NSDictionary *lastresult = [[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject];

		message = ([[lastresult objectForKey:@"Msg_type"] isEqualToString:@"status"]) ? NSLocalizedString(@"Successfully flushed table.",@"flush table successfully passed message") : NSLocalizedString(@"Flush table failed.", @"flush table failed message");

		message = [NSString stringWithFormat:@"%@\n\nMySQL said: %@", message, [lastresult objectForKey:@"Msg_text"]];
	} else if(statusOK) {
		message = NSLocalizedString(@"Successfully flushed all selected items.",@"successfully flushed all selected items message");
	}

	if(message) {
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:@"Flush %@", what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:message] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		message = NSLocalizedString(@"MySQL said:",@"mysql said message");
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:message];
		[alert setMessageText:NSLocalizedString(@"Error while flushing selected items", @"error while flushing selected items message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Runs a MySQL checksum on the selected table and present the result to the user via an alert sheet.
 */
- (IBAction)checksumTable:(id)sender
{
	NSArray *selectedItems = [tablesListInstance selectedTableItems];
	id message = nil;

	if([selectedItems count] == 0) return;

	MCPResult *theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"CHECKSUM TABLE %@", [selectedItems componentsJoinedAndBacktickQuoted]]];

	NSString *what = ([selectedItems count]>1) ? NSLocalizedString(@"selected items", @"selected items") : [NSString stringWithFormat:@"%@ '%@'", NSLocalizedString(@"table", @"table"), [self table]];

	// Check for errors, only displaying if the connection hasn't been terminated
	if ([mySQLConnection queryErrored]) {
		if ([mySQLConnection isConnected]) {

			[[NSAlert alertWithMessageText:NSLocalizedString(@"Unable to perform the checksum", @"unable to perform the checksum")
							 defaultButton:@"OK" 
						   alternateButton:nil 
							   otherButton:nil 
				 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while performing the checksum on %@.\n\nMySQL said:%@",@"an error occurred while performing the checksum on the %@.\n\nMySQL said:%@"), what, [mySQLConnection getLastErrorMessage]]] 
				  beginSheetModalForWindow:tableWindow 
							 modalDelegate:self 
							didEndSelector:NULL 
							   contextInfo:NULL];
		}

		return;
	}

	// Process result
	if([selectedItems count] == 1) {
		message = [[[theResult fetch2DResultAsType:MCPTypeDictionary] lastObject]  objectForKey:@"Checksum"];
		[[NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Checksum %@",@"checksum %@ message"), what] 
						 defaultButton:@"OK" 
					   alternateButton:nil 
						   otherButton:nil 
			 informativeTextWithFormat:[NSString stringWithFormat:NSLocalizedString(@"Table checksum: %@",@"table checksum: %@"), message]] 
			  beginSheetModalForWindow:tableWindow 
						 modalDelegate:self 
						didEndSelector:NULL 
						   contextInfo:NULL];
	} else {
		NSDictionary *result = [theResult fetch2DResultAsType:MCPTypeDictionary];
		if (statusValues) [statusValues release], statusValues = nil;
		statusValues = [result retain];
		NSAlert *alert = [[NSAlert new] autorelease];
		[alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Checksums of %@",@"Checksums of %@ message"), what]];
		[alert setMessageText:NSLocalizedString(@"Table checksum",@"table checksum message")];
		[alert setAccessoryView:statusTableAccessoryView];
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"statusError"];
	}
}

/**
 * Saves the current tables create syntax to the selected file.
 */
- (IBAction)saveCreateSyntax:(id)sender
{
	NSSavePanel *panel = [NSSavePanel savePanel];

	[panel setRequiredFileType:@"sql"];

	[panel setExtensionHidden:NO];
	[panel setAllowsOtherFileTypes:YES];
	[panel setCanSelectHiddenExtension:YES];

	[panel beginSheetForDirectory:nil file:@"CreateSyntax" modalForWindow:createTableSyntaxWindow modalDelegate:self didEndSelector:@selector(savePanelDidEnd:returnCode:contextInfo:) contextInfo:@"CreateSyntax"];
}

/**
 * Copy the create syntax in the create syntax text view to the pasteboard.
 */
- (IBAction)copyCreateTableSyntaxFromSheet:(id)sender
{
	NSString *createSyntax = [createTableSyntaxTextView string];

	if ([createSyntax length] > 0) {
		// Copy to the clipboard
		NSPasteboard *pb = [NSPasteboard generalPasteboard];

		[pb declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:self];
		[pb setString:createSyntax forType:NSStringPboardType];

		// Table syntax copied Growl notification
		[[SPGrowlController sharedGrowlController] notifyWithTitle:@"Syntax Copied"
													   description:[NSString stringWithFormat:NSLocalizedString(@"Syntax for %@ table copied", @"description for table syntax copied growl notification"), [self table]]
															window:tableWindow
												  notificationName:@"Syntax Copied"];
	}
}

/**
 * Switches to the content view and makes the filter field the first responder (has focus).
 */
- (IBAction)focusOnTableContentFilter:(id)sender
{
	[self viewContent:self];
	
	[tableContentInstance performSelector:@selector(makeContentFilterHaveFocus) withObject:nil afterDelay:0.1];
}

/**
 * Makes the tables list filter field the first responder.
 */
- (IBAction)focusOnTableListFilter:(id)sender
{
	[tablesListInstance performSelector:@selector(makeTableListFilterHaveFocus) withObject:nil afterDelay:0.1];
}

#pragma mark -
#pragma mark Other Methods

/**
 * Set that query which will be inserted into the Query Editor
 * after establishing the connection
 */

- (void)initQueryEditorWithString:(NSString *)query
{
	queryEditorInitString = [query retain];
}

/**
 * Invoked when user hits the cancel button or close button in
 * dialogs such as the variableSheet or the createTableSyntaxSheet
 */
- (IBAction)closeSheet:(id)sender
{
	[NSApp stopModalWithCode:0];
}

/**
 * Closes either the server variables or create syntax sheets.
 */
- (IBAction)closePanelSheet:(id)sender
{
	[NSApp endSheet:[sender window] returnCode:[sender tag]];
	[[sender window] orderOut:self];
}

/**
 * Displays the user account manager.
 */
- (IBAction)showUserManager:(id)sender
{	
	// Before displaying the user manager make sure the current user has access to the mysql.user table.
	MCPResult *result = [mySQLConnection queryString:@"SELECT * FROM `mysql`.`user` ORDER BY `user`"];
	
	if ([mySQLConnection queryErrored] && ([result numOfRows] == 0)) {
		
		NSAlert *alert = [NSAlert alertWithMessageText:NSLocalizedString(@"Unable to get list of users", @"unable to get list of users message")
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										   otherButton:nil 
							 informativeTextWithFormat:NSLocalizedString(@"An error occurred while trying to get the list of users. Please make sure you have the necessary privileges to perform user management, including access to the mysql.user table.", @"unable to get list of users informative message")];
		
		[alert setAlertStyle:NSCriticalAlertStyle];
		
		[alert beginSheetModalForWindow:tableWindow modalDelegate:self didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:) contextInfo:@"cannotremovefield"];
	
		return;
	}
	
	[NSApp beginSheet:[userManagerInstance window]
	   modalForWindow:tableWindow 
		modalDelegate:userManagerInstance 
	   didEndSelector:@selector(userManagerSheetDidEnd:returnCode:contextInfo:)
		  contextInfo:nil];
}

/**
 * Passes query to tablesListInstance
 */
- (void)doPerformQueryService:(NSString *)query
{
	[tableWindow makeKeyAndOrderFront:self];
	[tablesListInstance doPerformQueryService:query];
}

/**
 * Inserts query into the Custom Query editor
 */
- (void)doPerformLoadQueryService:(NSString *)query
{
	[self viewQuery:nil];
	[customQueryInstance doPerformLoadQueryService:query];
}

/**
 * Flushes the mysql privileges
 */
- (void)flushPrivileges:(id)sender
{
	[mySQLConnection queryString:@"FLUSH PRIVILEGES"];

	if (![mySQLConnection queryErrored]) {
		//flushed privileges without errors
		SPBeginAlertSheet(NSLocalizedString(@"Flushed Privileges", @"title of panel when successfully flushed privs"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, NSLocalizedString(@"Successfully flushed privileges.", @"message of panel when successfully flushed privs"));
	} else {
		//error while flushing privileges
		SPBeginAlertSheet(NSLocalizedString(@"Error", @"error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, [NSString stringWithFormat:NSLocalizedString(@"Couldn't flush privileges.\nMySQL said: %@", @"message of panel when flushing privs failed"),
																																					  [mySQLConnection getLastErrorMessage]]);
	}
}

- (IBAction)openCurrentConnectionInNewWindow:(id)sender
{
	TableDocument *newTableDocument;

	// Manually open a new document, setting SPAppController as sender to trigger autoconnection
	if (newTableDocument = [[NSDocumentController sharedDocumentController] makeUntitledDocumentOfType:@"Sequel Pro connection" error:nil]) {
		[newTableDocument setShouldAutomaticallyConnect:NO];
		[[NSDocumentController sharedDocumentController] addDocument:newTableDocument];
		[newTableDocument makeWindowControllers];
		[newTableDocument showWindows];
		[newTableDocument initWithConnectionFile:[[self fileURL] path]];
	}
}

- (void)closeConnection
{
	[mySQLConnection disconnect];
	_isConnected = NO;

	// Disconnected Growl notification
	[[SPGrowlController sharedGrowlController] notifyWithTitle:@"Disconnected" 
												   description:[NSString stringWithFormat:NSLocalizedString(@"Disconnected from %@",@"description for disconnected growl notification"), [tableWindow title]] 
														window:tableWindow
											  notificationName:@"Disconnected"];
}

/**
 * This method is called as part of Key Value Observing which is used to watch for prefernce changes which effect the interface.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ([keyPath isEqualToString:SPConsoleEnableLogging]) {
		[mySQLConnection setDelegateQueryLogging:[[change objectForKey:NSKeyValueChangeNewKey] boolValue]];
	}
}

/*
 * Is current document Untitled?
 */
- (BOOL)isUntitled
{
	return ([[self fileURL] isFileURL]) ? NO : YES;
}

#pragma mark -
#pragma mark Accessor methods

/**
 * Returns the host
 */
- (NSString *)host
{
	if ([connectionController type] == SPSocketConnection) return @"localhost";
	NSString *theHost = [connectionController host];
	if (!theHost) theHost = @"";
	return theHost;
}

/**
 * Returns the name
 */
- (NSString *)name
{
	if ([connectionController name] && [[connectionController name] length]) {
		return [connectionController name];
	}
	if ([connectionController type] == SPSocketConnection) {
		return [NSString stringWithFormat:@"%@@localhost", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous"];
	}
	return [NSString stringWithFormat:@"%@@%@", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", [connectionController host]?[connectionController host]:@""];
}

/**
 * Returns a string to identify the connection uniquely (mainly used to set up db structure with unique keys)
 */
- (NSString *)connectionID
{

	if(!_isConnected) return @"_";

	NSString *port;
	if([[self port] length])
		port = [NSString stringWithFormat:@":%@", [self port]];
	else
		port = @"";

	switch([connectionController type]) {
		case SPSocketConnection:
		return [NSString stringWithFormat:@"%@@localhost%@", ([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", port];
		break;
		case SPTCPIPConnection:
		return [NSString stringWithFormat:@"%@@%@%@", 
			([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", 
			[connectionController host]?[connectionController host]:@"", 
			port];
		break;
		case SPSSHTunnelConnection:
		return [NSString stringWithFormat:@"%@@%@%@&SSH&%@@%@:%@", 
			([connectionController user] && [[connectionController user] length])?[connectionController user]:@"anonymous", 
			[connectionController host]?[connectionController host]:@"", 
			port,
			([connectionController sshUser] && [[connectionController sshUser] length])?[connectionController sshUser]:@"anonymous",
			[connectionController sshHost]?[connectionController sshHost]:@"", 
			([[connectionController sshPort] length])?[connectionController sshPort]:@"22"];
	}

	return @"_";

}

/**
 * Returns the currently selected database
 */
- (NSString *)database
{
	return selectedDatabase;
}

/**
 * Returns the currently selected table (passing the request to TablesList)
 */
- (NSString *)table
{
	return [tablesListInstance tableName];
}

/**
 * Returns the MySQL version
 */
- (NSString *)mySQLVersion
{
	return mySQLVersion;
}

/**
 * Returns the current user
 */
- (NSString *)user
{
	NSString *theUser = [connectionController user];
	if (!theUser) theUser = @"";
	return theUser;
}

/**
 * Returns the current host's port
 */
- (NSString *)port
{
	NSString *thePort = [connectionController port];
	if (!thePort) return @"";
	return thePort;
}

- (NSString *)keyChainID
{
	return keyChainID;
}

#pragma mark -
#pragma mark Notification center methods

/**
 * Invoked before a query is performed
 */
- (void)willPerformQuery:(NSNotification *)notification
{
	[queryProgressBar startAnimation:self];
}

/**
 * Invoked after a query has been performed
 */
- (void)hasPerformedQuery:(NSNotification *)notification
{
	[queryProgressBar stopAnimation:self];
}

/**
 * Invoked when the application will terminate
 */
- (void)applicationWillTerminate:(NSNotification *)notification
{
	// Auto-save preferences to spf file based connection
	if([self fileURL] && [[[self fileURL] path] length] && ![self isUntitled])
		if(_isConnected && ![self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:YES]) {
			NSLog(@"Preference data for file ‘%@’ could not be saved.", [[self fileURL] path]);
			NSBeep();
		}

	[tablesListInstance selectionShouldChangeInTableView:nil];
}

#pragma mark -
#pragma mark Menu methods


/**
 * Saves SP session or if Custom Query tab is active the editor's content as SQL file
 * If sender == nil then the call came from [self writeSafelyToURL:ofType:forSaveOperation:error]
 */
- (IBAction)saveConnectionSheet:(id)sender
{

	NSSavePanel *panel = [NSSavePanel savePanel];
	NSString *filename;
	NSString *contextInfo;

	[panel setAllowsOtherFileTypes:NO];
	[panel setCanSelectHiddenExtension:YES];

	// Save Query…
	if( sender != nil && [sender tag] == 1006 ) {

		// Save the editor's content as SQL file
		[panel setAccessoryView:[SPEncodingPopupAccessory encodingAccessory:[prefs integerForKey:SPLastSQLFileEncoding] 
				includeDefaultEntry:NO encodingPopUp:&encodingPopUp]];
		// [panel setMessage:NSLocalizedString(@"Save SQL file", @"Save SQL file")];
		[panel setAllowedFileTypes:[NSArray arrayWithObjects:@"sql", nil]];
		if(![prefs stringForKey:@"lastSqlFileName"]) {
			[prefs setObject:@"" forKey:@"lastSqlFileName"];
			[prefs synchronize];
		}

		filename = [prefs stringForKey:@"lastSqlFileName"];
		contextInfo = @"saveSQLfile";

		// If no lastSqlFileEncoding in prefs set it to UTF-8
		if(![prefs integerForKey:SPLastSQLFileEncoding]) {
			[prefs setInteger:4 forKey:SPLastSQLFileEncoding];
			[prefs synchronize];
		}

		[encodingPopUp setEnabled:YES];

	// Save As… or Save
	} else if(sender == nil || [sender tag] == 1005 || [sender tag] == 1004) {

		// If Save was invoked check for fileURL and Untitled docs and save the spf file without save panel
		// otherwise ask for file name
		if(sender != nil && [sender tag] == 1004 && [[[self fileURL] path] length] && ![self isUntitled]) {
			[self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:NO];
			return;
		}

		// Load accessory nib each time
		if(![NSBundle loadNibNamed:@"SaveSPFAccessory" owner:self]) {
			NSLog(@"SaveSPFAccessory accessory dialog could not be loaded.");
			return;
		}

		// Save current session (open connection windows as SPF file)
		[panel setAllowedFileTypes:[NSArray arrayWithObjects:@"spf", nil]];

		//Restore accessory view settings if possible
		if([spfDocData objectForKey:@"save_password"])
			[saveConnectionSavePassword setState:[[spfDocData objectForKey:@"save_password"] boolValue]];
		if([spfDocData objectForKey:@"auto_connect"])
			[saveConnectionAutoConnect setState:[[spfDocData objectForKey:@"auto_connect"] boolValue]];
		if([spfDocData objectForKey:@"encrypted"])
			[saveConnectionEncrypt setState:[[spfDocData objectForKey:@"encrypted"] boolValue]];
		if([spfDocData objectForKey:@"include_session"])
			[saveConnectionIncludeData setState:[[spfDocData objectForKey:@"include_session"] boolValue]];
		if([spfDocData objectForKey:@"include_session"])
			[saveConnectionIncludeQuery setState:[[spfDocData objectForKey:@"save_editor_content"] boolValue]];

		[saveConnectionIncludeQuery setEnabled:([[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] length])];

		// Update accessory button states
		[self validateSaveConnectionAccessory:nil];

		// TODO note: it seems that one has problems with a NSSecureTextField
		// inside an accessory view - ask HansJB
		[[saveConnectionEncryptString cell] setControlView:saveConnectionAccessory];
		[panel setAccessoryView:saveConnectionAccessory];

		// Set file name
		if([[[self fileURL] path] length])
			filename = [self displayName];
		else
			filename = [NSString stringWithFormat:@"%@", [self name]];

		if(sender == nil)
			contextInfo = @"saveSPFfileAndClose";
		else
			contextInfo = @"saveSPFfile";

	} else {
		return;
	}

	[panel beginSheetForDirectory:nil 
						   file:filename 
				 modalForWindow:tableWindow 
				  modalDelegate:self 
				 didEndSelector:@selector(saveConnectionPanelDidEnd:returnCode:contextInfo:) 
					contextInfo:contextInfo];
}
/**
 * Control the save connection panel's accessory view
 */
- (IBAction)validateSaveConnectionAccessory:(id)sender
{

	// [saveConnectionAutoConnect setEnabled:([saveConnectionSavePassword state] == NSOnState)];
	[saveConnectionSavePasswordAlert setHidden:([saveConnectionSavePassword state] == NSOffState)];

	// If user checks the Encrypt check box set focus to password field
	if(sender == saveConnectionEncrypt && [saveConnectionEncrypt state] == NSOnState)
		[saveConnectionEncryptString selectText:sender];

	// Unfocus saveConnectionEncryptString
	if(sender == saveConnectionEncrypt && [saveConnectionEncrypt state] == NSOffState) {
		// [saveConnectionEncryptString setStringValue:[saveConnectionEncryptString stringValue]];
		// TODO how can one make it better ?
		[[saveConnectionEncryptString window] makeFirstResponder:[[saveConnectionEncryptString window] initialFirstResponder]];
	}

}

- (void)saveConnectionPanelDidEnd:(NSSavePanel *)panel returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{

	if ( returnCode ) {

		NSString *fileName = [panel filename];
		NSError *error = nil;

		// Save file as SQL file by using the chosen encoding
		if(contextInfo == @"saveSQLfile") {

			[prefs setInteger:[[encodingPopUp selectedItem] tag] forKey:SPLastSQLFileEncoding];
			[prefs setObject:[fileName lastPathComponent] forKey:@"lastSqlFileName"];
			[prefs synchronize];

			NSString *content = [NSString stringWithString:[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string]];
			[content writeToFile:fileName
					  atomically:YES
						encoding:[[encodingPopUp selectedItem] tag]
						   error:&error];

			if(error != nil) {
				NSAlert *errorAlert = [NSAlert alertWithError:error];
				[errorAlert runModal];
			}

			[[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

			return;
		}

		// Save connection and session as SPF file
		else if(contextInfo == @"saveSPFfile" || contextInfo == @"saveSPFfileAndClose") {
			// Save changes of saveConnectionEncryptString
			[[saveConnectionEncryptString window] makeFirstResponder:[[saveConnectionEncryptString window] initialFirstResponder]];

			[self saveDocumentWithFilePath:fileName inBackground:NO onlyPreferences:NO];

			if(contextInfo == @"saveSPFfileAndClose")
				[self close];
		}
	}
}

- (BOOL)saveDocumentWithFilePath:(NSString *)fileName inBackground:(BOOL)saveInBackground onlyPreferences:(BOOL)saveOnlyPreferences
{
	// Do not save if no connection is/was available
	if(saveInBackground && ([self mySQLVersion] == nil || ![[self mySQLVersion] length]))
		return NO;

	NSMutableDictionary *spfDocData_temp = [NSMutableDictionary dictionary];

	if(fileName == nil)
		fileName = [[self fileURL] path]; //[[[self fileURL] absoluteString] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

	// Store save panel settings or take them from spfDocData
	if(!saveInBackground) {
		[spfDocData_temp setObject:[NSNumber numberWithBool:([saveConnectionEncrypt state]==NSOnState) ? YES : NO ] forKey:@"encrypted"];
		if([[spfDocData_temp objectForKey:@"encrypted"] boolValue])
			[spfDocData_temp setObject:[saveConnectionEncryptString stringValue] forKey:@"e_string"];
		[spfDocData_temp setObject:[NSNumber numberWithBool:([saveConnectionAutoConnect state]==NSOnState) ? YES : NO ] forKey:@"auto_connect"];
		[spfDocData_temp setObject:[NSNumber numberWithBool:([saveConnectionSavePassword state]==NSOnState) ? YES : NO ] forKey:@"save_password"];
		[spfDocData_temp setObject:[NSNumber numberWithBool:([saveConnectionIncludeData state]==NSOnState) ? YES : NO ] forKey:@"include_session"];
		[spfDocData_temp setObject:[NSNumber numberWithBool:NO] forKey:@"save_editor_content"];
		if([[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] length])
			[spfDocData_temp setObject:[NSNumber numberWithBool:([saveConnectionIncludeQuery state]==NSOnState) ? YES : NO ] forKey:@"save_editor_content"];

	} else {
		[spfDocData_temp addEntriesFromDictionary:spfDocData];
	}

	// Update only query favourites, history, etc. by reading the file again
	if(saveOnlyPreferences) {

		// Check URL for safety reasons
		if(![[[self fileURL] path] length] || [self isUntitled]) {
			NSLog(@"Couldn't save data. No file URL found!");
			NSBeep();
			return NO;
		}

		NSError *readError = nil;
		NSString *convError = nil;
		NSPropertyListFormat format;
		NSMutableDictionary *spf = [[NSMutableDictionary alloc] init];

		NSData *pData = [NSData dataWithContentsOfFile:fileName options:NSUncachedRead error:&readError];

		[spf addEntriesFromDictionary:[NSPropertyListSerialization propertyListFromData:pData 
				mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&convError]];

		if(!spf || ![spf count] || readError != nil || [convError length] || !(format == NSPropertyListXMLFormat_v1_0 || format == NSPropertyListBinaryFormat_v1_0)) {
			NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while reading connection data file", @"error while reading connection data file")]
											 defaultButton:NSLocalizedString(@"OK", @"OK button") 
										   alternateButton:nil 
											  otherButton:nil 
								informativeTextWithFormat:NSLocalizedString(@"Connection data file couldn't be read. Please try to save the document under a different name.", @"message error while reading connection data file and suggesting to save it under a differnet name")];

			[alert setAlertStyle:NSCriticalAlertStyle];
			[alert runModal];
			if (spf) [spf release];
			// [self close];
			return NO;
		}

		// For dispatching later
		if(![[spf objectForKey:@"format"] isEqualToString:@"connection"]) {
			NSLog(@"SPF file format is not 'connection'.");
			[spf release];
			return NO;
		}

		// Update the keys
		[spf setObject:[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] forKey:SPQueryFavorites];
		[spf setObject:[[SPQueryController sharedQueryController] historyForFileURL:[self fileURL]] forKey:SPQueryHistory];
		[spf setObject:[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] forKey:SPContentFilters];

		// Save it again
		NSString *err = nil;
		NSData *plist = [NSPropertyListSerialization dataFromPropertyList:spf
												  format:NSPropertyListXMLFormat_v1_0
										errorDescription:&err];

		[spf release];
		if(err != nil) {
			NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while converting connection data", @"error while converting connection data")]
											 defaultButton:NSLocalizedString(@"OK", @"OK button") 
										   alternateButton:nil 
											  otherButton:nil 
								informativeTextWithFormat:err];

			[alert setAlertStyle:NSCriticalAlertStyle];
			[alert runModal];
			return NO;
		}

		NSError *error = nil;
		[plist writeToFile:fileName options:NSAtomicWrite error:&error];
		if(error != nil){
			NSAlert *errorAlert = [NSAlert alertWithError:error];
			[errorAlert runModal];
			return NO;
		}

		[[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

		return YES;

	}

	NSString *aString;

	NSMutableDictionary *spfdata = [NSMutableDictionary dictionary];
	NSMutableDictionary *connection = [NSMutableDictionary dictionary];
	NSMutableDictionary *session = nil;
	NSMutableDictionary *data = [NSMutableDictionary dictionary];

	NSIndexSet *contentSelectedIndexSet = [tableContentInstance selectedRowIndexes];

	[spfdata setObject:[NSNumber numberWithInteger:1] forKey:@"version"];
	[spfdata setObject:@"connection" forKey:@"format"];
	[spfdata setObject:@"mysql" forKey:@"rdbms_type"];
	[spfdata setObject:[self mySQLVersion] forKey:@"rdbms_version"];

	// Store the preferences - take them from the current document URL to catch renaming
	[spfdata setObject:[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] forKey:SPQueryFavorites];
	[spfdata setObject:[[SPQueryController sharedQueryController] historyForFileURL:[self fileURL]] forKey:SPQueryHistory];
	[spfdata setObject:[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] forKey:SPContentFilters];

	[spfdata setObject:[spfDocData_temp objectForKey:@"encrypted"] forKey:@"encrypted"];

	// if([[spfDocData_temp objectForKey:@"save_password"] boolValue])
	[spfdata setObject:[spfDocData_temp objectForKey:@"auto_connect"] forKey:@"auto_connect"];

	if([[self keyChainID] length])
		[connection setObject:[self keyChainID] forKey:@"kcid"];
	[connection setObject:[self name] forKey:@"name"];
	[connection setObject:[self host] forKey:@"host"];
	[connection setObject:[self user] forKey:@"user"];

	switch([connectionController type]) {
		case SPTCPIPConnection:
		aString = @"SPTCPIPConnection";
		break;
		case SPSocketConnection:
		aString = @"SPSocketConnection";
		[connection setObject:[connectionController socket] forKey:@"socket"];
		break;
		case SPSSHTunnelConnection:
		aString = @"SPSSHTunnelConnection";
		[connection setObject:[connectionController sshHost] forKey:@"ssh_host"];
		[connection setObject:[connectionController sshUser] forKey:@"ssh_user"];
		if([connectionController sshPort] && [[connectionController sshPort] length])
			[connection setObject:[NSNumber numberWithInteger:[[connectionController sshPort] integerValue]] forKey:@"ssh_port"];
		break;
		default:
		aString = @"SPTCPIPConnection";
	}
	[connection setObject:aString forKey:@"type"];


	if([[spfDocData_temp objectForKey:@"save_password"] boolValue]) {
		NSString *pw = [self keychainPasswordForConnection:nil];
		if(![pw length]) pw = [connectionController password];
		[connection setObject:pw forKey:@"password"];
		if([connectionController type] == SPSSHTunnelConnection)
			[connection setObject:[connectionController sshPassword] forKey:@"ssh_password"];
	}

	if([connectionController port] && [[connectionController port] length])
		[connection setObject:[NSNumber numberWithInteger:[[connectionController port] integerValue]] forKey:@"port"];

	if([[self database] length])
		[connection setObject:[self database] forKey:@"database"];

	// Include session data like selected table, view etc. ?
	if([[spfDocData_temp objectForKey:@"include_session"] boolValue]) {

		session = [NSMutableDictionary dictionary];

		if([[self table] length])
			[session setObject:[self table] forKey:@"table"];
		if([tableContentInstance sortColumnName])
			[session setObject:[tableContentInstance sortColumnName] forKey:@"contentSortCol"];

		switch([spHistoryControllerInstance currentlySelectedView]){
			case SPHistoryViewStructure:
				aString = @"SP_VIEW_STRUCTURE";
				break;
			case SPHistoryViewContent:
				aString = @"SP_VIEW_CONTENT";
				break;
			case SPHistoryViewCustomQuery:
				aString = @"SP_VIEW_CUSTOMQUERY";
				break;
			case SPHistoryViewStatus:
				aString = @"SP_VIEW_STATUS";
				break;
			case SPHistoryViewRelations:
				aString = @"SP_VIEW_RELATIONS";
				break;
			case SPHistoryViewTriggers:
				aString = @"SP_VIEW_TRIGGERS";
				break;
			default:
				aString = @"SP_VIEW_STRUCTURE";
		}
		[session setObject:aString forKey:@"view"];

		[session setObject:[NSNumber numberWithBool:[[tableWindow toolbar] isVisible]] forKey:@"isToolbarVisible"];
		[session setObject:[self connectionEncoding] forKey:@"connectionEncoding"];

		[session setObject:[NSNumber numberWithBool:[tableContentInstance sortColumnIsAscending]] forKey:@"contentSortColIsAsc"];
		[session setObject:[NSNumber numberWithInteger:[tableContentInstance pageNumber]] forKey:@"contentPageNumber"];
		[session setObject:NSStringFromRect([tableContentInstance viewport]) forKey:@"contentViewport"];
		if([tableContentInstance filterSettings])
			[session setObject:[tableContentInstance filterSettings] forKey:@"contentFilter"];

		if (contentSelectedIndexSet && [contentSelectedIndexSet count]) {
			NSMutableArray *indices = [NSMutableArray array];
			NSUInteger indexBuffer[[contentSelectedIndexSet count]];
			NSUInteger limit = [contentSelectedIndexSet getIndexes:indexBuffer maxCount:[contentSelectedIndexSet count] inIndexRange:NULL];
			NSUInteger idx;
			for (idx = 0; idx < limit; idx++) {
				[indices addObject:[NSNumber numberWithInteger:indexBuffer[idx]]];
			}
			[session setObject:indices forKey:@"contentSelectedIndexSet"];
		}
	}

	if([[spfDocData_temp objectForKey:@"save_editor_content"] boolValue]) {
		if(session == nil)
			session = [NSMutableDictionary dictionary];

		if([[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] length] > 50000)
			[session setObject:[[[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] dataUsingEncoding:NSUTF8StringEncoding] compress] forKey:@"queries"];
		else
			[session setObject:[[[customQueryInstance valueForKeyPath:@"textView"] textStorage] string] forKey:@"queries"];
	}

	[data setObject:connection forKey:@"connection"];
	if(session != nil)
		[data setObject:session forKey:@"session"];

	if(![[spfDocData_temp objectForKey:@"encrypted"] boolValue]) {
		[spfdata setObject:data forKey:@"data"];
	} else {
		NSMutableData *encryptdata = [[[NSMutableData alloc] init] autorelease];
		NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:encryptdata] autorelease];
		[archiver encodeObject:data forKey:@"data"];
		[archiver finishEncoding];
		[spfdata setObject:[encryptdata dataEncryptedWithPassword:[spfDocData_temp objectForKey:@"e_string"]] forKey:@"data"];
	}

	NSString *err = nil;
	NSData *plist = [NSPropertyListSerialization dataFromPropertyList:spfdata
											  format:NSPropertyListXMLFormat_v1_0
									errorDescription:&err];

	if(err != nil) {
		NSAlert *alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"Error while converting connection data", @"error while converting connection data")]
										 defaultButton:NSLocalizedString(@"OK", @"OK button") 
									   alternateButton:nil 
										  otherButton:nil 
							informativeTextWithFormat:err];

		[alert setAlertStyle:NSCriticalAlertStyle];
		[alert runModal];
		return NO;
	}

	NSError *error = nil;
	[plist writeToFile:fileName options:NSAtomicWrite error:&error];
	if(error != nil){
		NSAlert *errorAlert = [NSAlert alertWithError:error];
		[errorAlert runModal];
		return NO;
	}

	// Register and update query favorites, content filter, and history for the (new) file URL
	NSMutableDictionary *preferences = [[NSMutableDictionary alloc] init];
	[preferences setObject:[spfdata objectForKey:SPQueryHistory] forKey:SPQueryHistory];
	[preferences setObject:[spfdata objectForKey:SPQueryFavorites] forKey:SPQueryFavorites];
	[preferences setObject:[spfdata objectForKey:SPContentFilters] forKey:SPContentFilters];
	[[SPQueryController sharedQueryController] registerDocumentWithFileURL:[NSURL fileURLWithPath:fileName] andContextInfo:preferences];

	[self setFileURL:[NSURL fileURLWithPath:fileName]];
	[[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:fileName]];

	[tableWindow setTitle:[self displaySPName]];

	// Store doc data permanently
	[spfDocData removeAllObjects];
	[spfDocData addEntriesFromDictionary:spfDocData_temp];

	[preferences release];

	return YES;

}

/**
 * Passes the request to the tableDump object
 */
- (IBAction)import:(id)sender
{
	[tableDumpInstance importFile];
}

/**
 * Passes the request to the tableDump object
 */
- (IBAction)export:(id)sender
{
	if ([sender tag] == -1) {
		[exportControllerInstance export];
	} 
	else {
		[tableDumpInstance exportFile:[sender tag]];
	}
}

- (IBAction)exportTable:(id)sender
{
	return [self export:sender];
}

- (IBAction)exportMultipleTables:(id)sender
{
	return [self export:sender];
}

/*
 * Show the MySQL Help TOC of the current MySQL connection
 * Invoked by the MainMenu > Help > MySQL Help
 */
- (IBAction)showMySQLHelp:(id)sender
{
	[customQueryInstance showHelpFor:SP_HELP_TOC_SEARCH_STRING addToHistory:YES calledByAutoHelp:NO];
	[[customQueryInstance helpWebViewWindow] makeKeyWindow];
}

/**
 * Menu item validation.
 */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if ([menuItem menu] == chooseDatabaseButton) {
		return (_isConnected && databaseListIsSelectable);
	}

	if (!_isConnected || _isWorkingLevel) {
		return ([menuItem action] == @selector(newDocument:) || [menuItem action] == @selector(terminate:));
	}

	if ([menuItem action] == @selector(openCurrentConnectionInNewWindow:))
	{
		if([self isUntitled]) {
			[menuItem setTitle:NSLocalizedString(@"Open in New Window", @"menu item open in new window")];
			return NO;
		} else {
			[menuItem setTitle:[NSString stringWithFormat:NSLocalizedString(@"Open “%@” in New Window", @"menu item open “%@” in new window"), [self displayName]]];
			return YES;
		}
	}

	if ([menuItem action] == @selector(import:) ||
		[menuItem action] == @selector(export:) ||
		[menuItem action] == @selector(exportMultipleTables:) ||
		[menuItem action] == @selector(removeDatabase:))
	{
		return ([self database] != nil);
	}

	// Change "Save Query/Queries" menu item title dynamically
	// and disable it if no query in the editor
	if ([menuItem action] == @selector(saveConnectionSheet:) && [menuItem tag] == 0) {
		if([customQueryInstance numberOfQueries] < 1) {
			[menuItem setTitle:NSLocalizedString(@"Save Query…", @"Save Query…")];
			return NO;
		}
		else if([customQueryInstance numberOfQueries] == 1)
			[menuItem setTitle:NSLocalizedString(@"Save Query…", @"Save Query…")];
		else
			[menuItem setTitle:NSLocalizedString(@"Save Queries…", @"Save Queries…")];

		return YES;
	}

	if ([menuItem action] == @selector(exportTable:)) {
		return ([self database] != nil && [self table] != nil);
	}

	if ([menuItem action] == @selector(printDocument:)) {
		return (([self database] != nil && [[tablesListInstance valueForKeyPath:@"tablesListView"] numberOfSelectedRows] == 1)
			// if Custom Query Tab is active the textView will handle printDocument by itself
			// if it is first responder; otherwise allow to print the Query Result table even 
			//if no db/table is selected
			|| [tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 2
			);
	}

	if ([menuItem action] == @selector(chooseEncoding:)) {
		return [self supportsEncoding];
	}

	// table menu items
	if ([menuItem action] == @selector(showCreateTableSyntax:) ||
		[menuItem action] == @selector(copyCreateTableSyntax:)) 
	{
		return ([self table] != nil && [[self table] isNotEqualTo:@""]);
	}

	if ([menuItem action] == @selector(analyzeTable:) || 
		[menuItem action] == @selector(optimizeTable:) || 
		[menuItem action] == @selector(repairTable:) || 
		[menuItem action] == @selector(flushTable:) ||
		[menuItem action] == @selector(checkTable:) ||
		[menuItem action] == @selector(checksumTable:))
	{
		return ([[[tablesListInstance valueForKeyPath:@"tablesListView"] selectedRowIndexes] count]) ? YES:NO;
	}

	if ([menuItem action] == @selector(addConnectionToFavorites:)) {
		return ([connectionController selectedFavorite] ? NO : YES);
	}

	// Backward in history menu item
	if (([menuItem action] == @selector(backForwardInHistory:)) && ([menuItem tag] == 0)) {
		return (([[spHistoryControllerInstance history] count]) && ([spHistoryControllerInstance historyPosition] > 0));
	}

	// Forward in history menu item
	if (([menuItem action] == @selector(backForwardInHistory:)) && ([menuItem tag] == 1)) {
		return (([[spHistoryControllerInstance history] count]) && (([spHistoryControllerInstance historyPosition] + 1) < [[spHistoryControllerInstance history] count]));
	}
	
	// Show/hide console
	if ([menuItem action] == @selector(toggleConsole:)) {
		[menuItem setTitle:([[[SPQueryController sharedQueryController] window] isVisible]) ? NSLocalizedString(@"Hide Console", @"hide console") : NSLocalizedString(@"Show Console", @"show console")];
	}
	
	// Clear console
	if ([menuItem action] == @selector(clearConsole:)) {
		return ([[SPQueryController sharedQueryController] consoleMessageCount] > 0);
	}
	
	// Show/hide console
	if ([menuItem action] == @selector(toggleNavigator:)) {
		[menuItem setTitle:([[[SPNavigatorController sharedNavigatorController] window] isVisible]) ? NSLocalizedString(@"Hide Navigator", @"hide navigator") : NSLocalizedString(@"Show Navigator", @"show navigator")];
	}
	
	// Focus on table content filter
	if ([menuItem action] == @selector(focusOnTableContentFilter:)) {
		return ([self table] != nil && [[self table] isNotEqualTo:@""]); 
	}

	// Focus on table list or filter resp.
	if ([menuItem action] == @selector(focusOnTableListFilter:)) {
		
		if([[tablesListInstance valueForKeyPath:@"tables"] count] > 20)
			[menuItem setTitle:NSLocalizedString(@"Filter Tables", @"filter tables menu item")];
		else
			[menuItem setTitle:NSLocalizedString(@"Change Focus to Table List", @"change focus to table list menu item")];
			
		return ([[tablesListInstance valueForKeyPath:@"tables"] count] > 1); 
	}
	
	// If validation for the sort favorites tableview items reaches here then the preferences window isn't
	// open return NO.
	if (([menuItem action] == @selector(sortFavorites:)) || ([menuItem action] == @selector(reverseFavoritesSortOrder:))) {
		return NO;
	}

	return [super validateMenuItem:menuItem];
}

- (IBAction)viewStructure:(id)sender
{
	// Cancel the selection if currently editing a content row and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 1
		&& ![tableContentInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
		return;
	}

	[tableTabView selectTabViewItemAtIndex:0];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
	[spHistoryControllerInstance updateHistoryEntries];
	
	[prefs setInteger:SPStructureViewMode forKey:SPLastViewMode];
}

- (IBAction)viewContent:(id)sender
{
	// Cancel the selection if currently editing structure/a field and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0
		&& ![tableSourceInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
		return;
	}

	[tableTabView selectTabViewItemAtIndex:1];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
	[spHistoryControllerInstance updateHistoryEntries];
	
	[prefs setInteger:SPContentViewMode forKey:SPLastViewMode];
}

- (IBAction)viewQuery:(id)sender
{
	// Cancel the selection if currently editing structure/a field and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0
		&& ![tableSourceInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
		return;
	}

	// Cancel the selection if currently editing a content row and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 1
		&& ![tableContentInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
		return;
	}

	[tableTabView selectTabViewItemAtIndex:2];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarCustomQuery];
	[spHistoryControllerInstance updateHistoryEntries];

	// Set the focus on the text field if no query has been run
	if (![[customQueryTextView string] length]) [tableWindow makeFirstResponder:customQueryTextView];
	
	[prefs setInteger:SPQueryEditorViewMode forKey:SPLastViewMode];
}

- (IBAction)viewStatus:(id)sender
{
	// Cancel the selection if currently editing structure/a field and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0
		&& ![tableSourceInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
		return;
	}

	// Cancel the selection if currently editing a content row and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 1
		&& ![tableContentInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
		return;
	}

	[tableTabView selectTabViewItemAtIndex:3];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableInfo];
	[spHistoryControllerInstance updateHistoryEntries];

	// Refresh data
	if([self table] && [[self table] length]) {
		[tableDataInstance resetAllData];
		[extendedTableInfoInstance loadTable:[self table]];
	}
	
	[tableWindow makeFirstResponder:[extendedTableInfoInstance valueForKeyPath:@"tableCreateSyntaxTextView"]];

	[prefs setInteger:SPTableInfoViewMode forKey:SPLastViewMode];
}

- (IBAction)viewRelations:(id)sender
{
	// Cancel the selection if currently editing structure/a field and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0
		&& ![tableSourceInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
		return;
	}

	// Cancel the selection if currently editing a content row and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 1
		&& ![tableContentInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
		return;
	}

	[tableTabView selectTabViewItemAtIndex:4];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableRelations];
	[spHistoryControllerInstance updateHistoryEntries];
	
	[prefs setInteger:SPRelationsViewMode forKey:SPLastViewMode];
}

- (IBAction)viewTriggers:(id)sender
{
	// Cancel the selection if currently editing structure/a field and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0
		&& ![tableSourceInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableStructure];
		return;
	}
	
	// Cancel the selection if currently editing a content row and unable to save
	if ([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 1
		&& ![tableContentInstance saveRowOnDeselect]) {
		[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableContent];
		return;
	}
	
	
	[tableTabView selectTabViewItemAtIndex:5];
	[mainToolbar setSelectedItemIdentifier:SPMainToolbarTableTriggers];
	[spHistoryControllerInstance updateHistoryEntries];
	
	[prefs setInteger:SPTriggersViewMode forKey:SPLastViewMode];
}


/**
 * Adds the current database connection details to the user's favorites if it doesn't already exist.
 */
- (IBAction)addConnectionToFavorites:(id)sender
{
	// Obviously don't add if it already exists. We shouldn't really need this as the menu item validation
	// enables or disables the menu item based on the same method. Although to be safe do the check anyway
	// as we don't know what's calling this method.
	if ([connectionController selectedFavorite]) {
		return;
	}

	// Request the connection controller to add its details to favorites
	[connectionController addFavorite:self];
}

/**
 * Called when the NSSavePanel sheet ends. Writes the server variables to the selected file if required.
 */
- (void)savePanelDidEnd:(NSSavePanel *)sheet returnCode:(NSInteger)returnCode contextInfo:(NSString *)contextInfo
{
	if (returnCode == NSOKButton) {
		if ([contextInfo isEqualToString:@"CreateSyntax"]) {

			NSString *createSyntax = [createTableSyntaxTextView string];

			if ([createSyntax length] > 0) {
				NSString *output = [NSString stringWithFormat:@"-- Create syntax for '%@'\n\n%@\n", [self table], createSyntax]; 

				[output writeToFile:[sheet filename] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
			}
		}
	}
}

/*
 * Return the createTableSyntaxWindow
 */
- (NSWindow *)getCreateTableSyntaxWindow
{
	return createTableSyntaxWindow;
}

#pragma mark -
#pragma mark Titlebar Methods

/**
 * Set the connection status icon in the titlebar
 */
- (void)setStatusIconToImageWithName:(NSString *)imageName
{
	NSString *imagePath = [[NSBundle mainBundle] pathForResource:imageName ofType:@"png"];
	if (!imagePath) return;

	NSImage *image = [[[NSImage alloc] initByReferencingFile:imagePath] autorelease];
	[titleImageView setImage:image];
}

- (void)setTitlebarStatus:(NSString *)status
{
	[self clearStatusIcon];
	[titleStringView setStringValue:status];
}

/**
 * Clear the connection status icon in the titlebar
 */
- (void)clearStatusIcon
{
	[titleImageView setImage:nil];
}

#pragma mark -
#pragma mark Toolbar Methods

/**
 * set up the standard toolbar
 */
- (void)setupToolbar
{
	// create a new toolbar instance, and attach it to our document window 
	mainToolbar = [[[NSToolbar alloc] initWithIdentifier:@"TableWindowToolbar"] autorelease];

	// set up toolbar properties
	[mainToolbar setAllowsUserCustomization:YES];
	[mainToolbar setAutosavesConfiguration:YES];
	[mainToolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];

	// set ourself as the delegate
	[mainToolbar setDelegate:self];

	// attach the toolbar to the document window
	[tableWindow setToolbar:mainToolbar];

	// update the toolbar item size
	[self updateChooseDatabaseToolbarItemWidth];
}

/**
 * Return the identifier for the currently selected toolbar item, or nil if none is selected.
 */
- (NSString *)selectedToolbarItemIdentifier;
{
	return [mainToolbar selectedItemIdentifier];
}

/**
 * toolbar delegate method
 */
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)willBeInsertedIntoToolbar
{
	NSToolbarItem *toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

	if ([itemIdentifier isEqualToString:SPMainToolbarDatabaseSelection]) {
		[toolbarItem setLabel:NSLocalizedString(@"Select Database", @"toolbar item for selecting a db")];
		[toolbarItem setPaletteLabel:[toolbarItem label]];
		[toolbarItem setView:chooseDatabaseButton];
		[toolbarItem setMinSize:NSMakeSize(200,26)];
		[toolbarItem setMaxSize:NSMakeSize(200,32)];
		[chooseDatabaseButton setTarget:self];
		[chooseDatabaseButton setAction:@selector(chooseDatabase:)];

		if (willBeInsertedIntoToolbar) {
			chooseDatabaseToolbarItem = toolbarItem;
			[self updateChooseDatabaseToolbarItemWidth];
		} 

	} else if ([itemIdentifier isEqualToString:SPMainToolbarHistoryNavigation]) {
		[toolbarItem setLabel:NSLocalizedString(@"Table History", @"toolbar item for navigation history")];
		[toolbarItem setPaletteLabel:[toolbarItem label]];
		[toolbarItem setView:historyControl];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarShowConsole]) {
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Show Console", @"show console")];
		[toolbarItem setToolTip:NSLocalizedString(@"Show the console which shows all MySQL commands performed by Sequel Pro", @"tooltip for toolbar item for show console")];

		[toolbarItem setLabel:NSLocalizedString(@"Console", @"Console")];
		[toolbarItem setImage:[NSImage imageNamed:@"hideconsole"]];

		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(showConsole:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarClearConsole]) {
		//set the text label to be displayed in the toolbar and customization palette 
		[toolbarItem setLabel:NSLocalizedString(@"Clear Console", @"toolbar item for clear console")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Clear Console", @"toolbar item for clear console")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Clear the console which shows all MySQL commands performed by Sequel Pro", @"tooltip for toolbar item for clear console")];
		[toolbarItem setImage:[NSImage imageNamed:@"clearconsole"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(clearConsole:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarTableStructure]) {
		[toolbarItem setLabel:NSLocalizedString(@"Structure", @"toolbar item label for switching to the Table Structure tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Edit Table Structure", @"toolbar item label for switching to the Table Structure tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Structure tab", @"tooltip for toolbar item for switching to the Table Structure tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-structure"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewStructure:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarTableContent]) {
		[toolbarItem setLabel:NSLocalizedString(@"Content", @"toolbar item label for switching to the Table Content tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Browse & Edit Table Content", @"toolbar item label for switching to the Table Content tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Content tab", @"tooltip for toolbar item for switching to the Table Content tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-browse"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewContent:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarCustomQuery]) {
		[toolbarItem setLabel:NSLocalizedString(@"Query", @"toolbar item label for switching to the Run Query tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Run Custom Query", @"toolbar item label for switching to the Run Query tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Run Query tab", @"tooltip for toolbar item for switching to the Run Query tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-sql"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewQuery:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarTableInfo]) {
		[toolbarItem setLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Table Info", @"toolbar item label for switching to the Table Info tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Info tab", @"tooltip for toolbar item for switching to the Table Info tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-table-info"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewStatus:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarTableRelations]) {
		[toolbarItem setLabel:NSLocalizedString(@"Relations", @"toolbar item label for switching to the Table Relations tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Table Relations", @"toolbar item label for switching to the Table Relations tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Relations tab", @"tooltip for toolbar item for switching to the Table Relations tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-table-relations"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewRelations:)];

	} else if ([itemIdentifier isEqualToString:SPMainToolbarTableTriggers]) {
		[toolbarItem setLabel:NSLocalizedString(@"Triggers", @"toolbar item label for switching to the Table Triggers tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Table Triggers", @"toolbar item label for switching to the Table Triggers tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the Table Triggers tab", @"tooltip for toolbar item for switching to the Table Triggers tab")];
		[toolbarItem setImage:[NSImage imageNamed:@"toolbar-switch-to-table-triggers"]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(viewTriggers:)];
		
	} else if ([itemIdentifier isEqualToString:SPMainToolbarUserManager]) {
		[toolbarItem setLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
		[toolbarItem setPaletteLabel:NSLocalizedString(@"Users", @"toolbar item label for switching to the User Manager tab")];
		//set up tooltip and image
		[toolbarItem setToolTip:NSLocalizedString(@"Switch to the User Manager tab", @"tooltip for toolbar item for switching to the User Manager tab")];
		[toolbarItem setImage:[NSImage imageNamed:NSImageNameEveryone]];
		//set up the target action
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(showUserManager:)];
		
	} else {
		//itemIdentifier refered to a toolbar item that is not provided or supported by us or cocoa 
		toolbarItem = nil;
	}

	return toolbarItem;
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:
			SPMainToolbarDatabaseSelection,
			SPMainToolbarHistoryNavigation,
			SPMainToolbarShowConsole,
			SPMainToolbarClearConsole,
			SPMainToolbarTableStructure,
			SPMainToolbarTableContent,
			SPMainToolbarCustomQuery,
			SPMainToolbarTableInfo,
			SPMainToolbarTableRelations,
			SPMainToolbarTableTriggers,
			SPMainToolbarUserManager,
			NSToolbarCustomizeToolbarItemIdentifier,
			NSToolbarFlexibleSpaceItemIdentifier,
			NSToolbarSpaceItemIdentifier,
			NSToolbarSeparatorItemIdentifier,
			nil];
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
	return [NSArray arrayWithObjects:
			SPMainToolbarDatabaseSelection,
			SPMainToolbarTableStructure,
			SPMainToolbarTableContent,
			SPMainToolbarTableRelations,
			SPMainToolbarTableInfo,
			SPMainToolbarCustomQuery,
			NSToolbarFlexibleSpaceItemIdentifier,
			SPMainToolbarHistoryNavigation,
			SPMainToolbarUserManager,
			SPMainToolbarShowConsole,
			nil];
}

/**
 * toolbar delegate method
 */
- (NSArray *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar
{
	return [NSArray arrayWithObjects:
			SPMainToolbarTableStructure,
			SPMainToolbarTableContent,
			SPMainToolbarCustomQuery,
			SPMainToolbarTableInfo,
			SPMainToolbarTableRelations,
			SPMainToolbarTableTriggers,
			nil];

}

/**
 * Validates the toolbar items
 */
- (BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem;
{
	if (!_isConnected || _isWorkingLevel) return NO;

	NSString *identifier = [toolbarItem itemIdentifier];

	// Show console item
	if ([identifier isEqualToString:SPMainToolbarShowConsole]) {
		if ([[[SPQueryController sharedQueryController] window] isVisible]) {
			[toolbarItem setImage:[NSImage imageNamed:@"showconsole"]];
		} else {
			[toolbarItem setImage:[NSImage imageNamed:@"hideconsole"]];
		}
		if ([[[SPQueryController sharedQueryController] window] isKeyWindow]) {
			return NO;
		} else {
			return YES;
		}
	}

	// Clear console item
	if ([identifier isEqualToString:SPMainToolbarClearConsole]) {
		return ([[SPQueryController sharedQueryController] consoleMessageCount] > 0);
	}

	if (![identifier isEqualToString:SPMainToolbarCustomQuery] && ![identifier isEqualToString:SPMainToolbarUserManager]) {
		return (([tablesListInstance tableType] == SPTableTypeTable) || 
				([tablesListInstance tableType] == SPTableTypeView));
	}

	return YES;
}

#pragma mark -
#pragma mark NSDocument methods

/**
 * Returns the name of the nib file
 */
- (NSString *)windowNibName
{
	return @"DBView";
}

/**
 * Code that need to be executed once the windowController has loaded the document's window
 * sets upt the interface (small fonts).
 */
- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
	[aController setShouldCascadeWindows:YES];
	[super windowControllerDidLoadNib:aController];

	//register for notifications
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willPerformQuery:)
												 name:@"SMySQLQueryWillBePerformed" object:self];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hasPerformedQuery:)
												 name:@"SMySQLQueryHasBeenPerformed" object:self];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:)
												 name:@"NSApplicationWillTerminateNotification" object:nil];
}

// NSWindow delegate methods

/**
 * Invoked when the document window is about to close
 */
- (void)windowWillClose:(NSNotification *)aNotification
{

	// Cancel autocompletion trigger
	if([prefs boolForKey:SPCustomQueryAutoComplete])
		[NSObject cancelPreviousPerformRequestsWithTarget:[customQueryInstance valueForKeyPath:@"textView"] 
								selector:@selector(doAutoCompletion) 
								object:nil];
	if([prefs boolForKey:SPCustomQueryUpdateAutoHelp])
		[NSObject cancelPreviousPerformRequestsWithTarget:[customQueryInstance valueForKeyPath:@"textView"] 
									selector:@selector(autoHelp) 
									object:nil];


	[[SPNavigatorController sharedNavigatorController] removeConnection:[self connectionID]];

	[mySQLConnection setDelegate:nil];
	if (_isConnected) [self closeConnection];
	else [connectionController cancelConnection];
	if ([[[SPQueryController sharedQueryController] window] isVisible]) [self toggleConsole:self];
	[createTableSyntaxWindow orderOut:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

/**
 * Invoked when the document window should close
 */
- (BOOL)windowShouldClose:(id)sender
{

	// If no connection is available, always return YES.  Covers initial setup and disconnections.
	if(!_isConnected) return YES;

	// If tasks are active, return NO to allow tasks to complete
	if (_isWorkingLevel) return NO;

	// If the table list considers itself to be working, return NO. This catches open alerts, and
	// edits in progress in various views.
	if ( ![tablesListInstance selectionShouldChangeInTableView:nil] ) return NO;

	// Auto-save spf file based connection and return whether the save was successful
	if([self fileURL] && [[[self fileURL] path] length] && ![self isUntitled]) {
		BOOL isSaved = [self saveDocumentWithFilePath:nil inBackground:YES onlyPreferences:YES];
		if(isSaved)
			[[SPQueryController sharedQueryController] removeRegisteredDocumentWithFileURL:[self fileURL]];
		return isSaved;
	}

	// Return YES by default
	return YES;
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	// Synchronize Navigator with current active document if Navigator runs in syncMode
	if([[SPNavigatorController sharedNavigatorController] syncMode] && [self connectionID] && ![[self connectionID] isEqualToString:@"_"]) {
		NSMutableString *schemaPath = [NSMutableString string];
		[schemaPath setString:[self connectionID]];
		if([self database] && [[self database] length]) {
			[schemaPath appendString:SPUniqueSchemaDelimiter];
			[schemaPath appendString:[self database]];
			if([self table] && [[self table] length]) {
				[schemaPath appendString:SPUniqueSchemaDelimiter];
				[schemaPath appendString:[self table]];
			}
		}
		[[SPNavigatorController sharedNavigatorController] selectPath:schemaPath];
	}
}

/**
 * Invoked when the document window is resized
 */
- (void)windowDidResize:(NSNotification *)notification
{

	// If the task interface is visible, re-center the task child window
	if (_isWorkingLevel) [self centerTaskWindow];
}

/**
 * Invoked when the user command-clicks on the window title to see the document path
 */
- (BOOL)window:(NSWindow *)window shouldPopUpDocumentPathMenu:(NSMenu *)menu
{
	return ![self isUntitled];
}

/*
 * Invoked if user chose "Save" from 'Do you want save changes you made...' sheet
 * which is called automatically if [self isDocumentEdited] == YES and user wanted to close an Untitled doc.
 */
- (BOOL)writeSafelyToURL:(NSURL *)absoluteURL ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation error:(NSError **)outError
{
	if(saveOperation == NSSaveOperation) {
		// Dummy error to avoid crashes after Canceling the Save Panel
		if (outError) *outError = [NSError errorWithDomain:@"SP_DOMAIN" code:1000 userInfo:nil];
		[self saveConnectionSheet:nil];
		return NO;
	}
	return YES;
}

/**
 * Shows "save?" dialog when closing the document if the an Untitled doc has doc-based query favorites or content filters.
 */
- (BOOL)isDocumentEdited
{
	return ([self fileURL] && [[[self fileURL] path] length] && [self isUntitled] && ([[[SPQueryController sharedQueryController] favoritesForFileURL:[self fileURL]] count]
		|| [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"number"] count]
		|| [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"date"] count]
		|| [[[[SPQueryController sharedQueryController] contentFilterForFileURL:[self fileURL]] objectForKey:@"string"] count])
		);
}

/**
 * The window title for this document.
 */
- (NSString *)displaySPName
{
	if (!_isConnected) {
		return [NSString stringWithFormat:@"%@%@", 
				([[[self fileURL] path] length] && ![self isUntitled]) ? [NSString stringWithFormat:@"%@ — ",[[[self fileURL] path] lastPathComponent]] : @"", @"Sequel Pro"];

	} 
		
	return [NSString stringWithFormat:@"%@%@ %@%@%@", 
		([[[self fileURL] path] length] && ![self isUntitled]) ? [NSString stringWithFormat:@"%@ — ",[self displayName]] : @"",
		([prefs boolForKey:SPDisplayServerVersionInWindowTitle]) ? [NSString stringWithFormat:@"(MySQL %@)", mySQLVersion] : @"",
		[self name],
		([self database]?[NSString stringWithFormat:@"/%@",[self database]]:@""),
		([[self table] length]?[NSString stringWithFormat:@"/%@",[self table]]:@"")];
}
/**
 * The window title for this document.
 */
- (NSString *)displayName
{
	if(!_isConnected) return [self displaySPName];
	return [[[self fileURL] path] lastPathComponent];
}

#pragma mark -
#pragma mark Connection controller delegate methods

/**
 * Invoked by the connection controller when it starts the process of initiating a connection.
 */
- (void)connectionControllerInitiatingConnection:(id)controller
{
	// Update the window title to indicate that we are try to establish a connection
	[tableWindow setTitle:NSLocalizedString(@"Connecting…", @"window title string indicating that sp is connecting")];
}

/**
 * Invoked by the connection controller when the attempt to initiate a connection failed.
 */
- (void)connectionControllerConnectAttemptFailed:(id)controller
{
	// Reset the window title
	[tableWindow setTitle:[self displaySPName]];
}

#pragma mark -
#pragma mark Text field delegate methods

/**
 * When adding a database, enable the button only if the new name has a length.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
	id object = [notification object];

	if (object == databaseNameField) {
		[addDatabaseButton setEnabled:([[databaseNameField stringValue] length] > 0)]; 
	}
	else if (object == saveConnectionEncryptString) {
		[saveConnectionEncryptString setStringValue:[saveConnectionEncryptString stringValue]];
	}

}

#pragma mark -
#pragma mark General sheet delegate methods

- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect {

	// Locate the sheet "Reset Auto Increment" just centered beneath the chosen index row
	// if Structure Pane is active
	if([tableTabView indexOfTabViewItem:[tableTabView selectedTabViewItem]] == 0 
			&& [[sheet title] isEqualToString:@"Reset Auto Increment"]) {

		id it = [tableSourceInstance valueForKeyPath:@"indexView"];
		NSRect mwrect = [[NSApp mainWindow] frame];
		NSRect ltrect = [[tablesListInstance valueForKeyPath:@"tablesListView"] frame];
		NSRect rowrect = [it rectOfRow:[it selectedRow]];
		rowrect.size.width = mwrect.size.width - ltrect.size.width;
		rowrect.origin.y -= [it rowHeight]/2.0f+2;
		rowrect.origin.x -= 8;
		return [it convertRect:rowrect toView:nil];

	} else
		return rect;

}

#pragma mark -
#pragma mark SplitView delegate methods

/**
 * tells the splitView that it can collapse views
 */
- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview
{
	return subview == [[tableInfoTable superview] superview];
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification
{
	[self updateChooseDatabaseToolbarItemWidth];
}

- (NSRect)splitView:(NSSplitView *)splitView additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
	if (sidebarGrabber != nil) {
		return [sidebarGrabber convertRect:[sidebarGrabber bounds] toView:splitView];
	} else {
		return NSZeroRect;
	}
}

- (void)updateChooseDatabaseToolbarItemWidth
{
	// make sure the toolbar item is actually in the toolbar
	if (!chooseDatabaseToolbarItem)
		return;

	// grab the width of the left pane
	CGFloat leftPaneWidth = [[[contentViewSplitter subviews] objectAtIndex:0] frame].size.width;

	// subtract some pixels to allow for misc stuff
	leftPaneWidth -= 12;

	// make sure it's not too small or to big
	if (leftPaneWidth < 130)
		leftPaneWidth = 130;
	if (leftPaneWidth > 360)
		leftPaneWidth = 360;

	// apply the size
	[chooseDatabaseToolbarItem setMinSize:NSMakeSize(leftPaneWidth, 26)];
	[chooseDatabaseToolbarItem setMaxSize:NSMakeSize(leftPaneWidth, 32)];
}

#pragma mark -
#pragma mark Datasource methods

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	if(statusTableView && aTableView == statusTableView)
		return [statusValues count];
	return 0;
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	if(statusTableView && aTableView == statusTableView && rowIndex < [statusValues count]) {
		if ([[aTableColumn identifier] isEqualToString:@"table_name"]) {
			if([[statusValues objectAtIndex:rowIndex] objectForKey:@"table_name"])
				return [[statusValues objectAtIndex:rowIndex] objectForKey:@"table_name"];
			else if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Table"])
				return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Table"];
			return @"";
		}
		else if ([[aTableColumn identifier] isEqualToString:@"msg_status"]) {
			if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_type"])
				return [[[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_type"] capitalizedString];
			return @"";
		}
		else if ([[aTableColumn identifier] isEqualToString:@"msg_text"]) {
			if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_text"]) {
				[[aTableColumn headerCell] setStringValue:NSLocalizedString(@"Message",@"message column title")];
				return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Msg_text"];
			}
			else if([[statusValues objectAtIndex:rowIndex] objectForKey:@"Checksum"]) {
				[[aTableColumn headerCell] setStringValue:@"Checksum"];
				return [[statusValues objectAtIndex:rowIndex] objectForKey:@"Checksum"];
			}
			return @"";
		}
	}
	return nil;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	return NO;
}


#pragma mark -
#pragma mark status accessory view

- (IBAction)copyChecksumFromSheet:(id)sender
{
	NSMutableString *tmp = [NSMutableString string];
	for(id row in statusValues)
		if([row objectForKey:@"Msg_type"])
			[tmp appendFormat:@"%@\t%@\t%@\n", [[row objectForKey:@"Table"] description],
				[[row objectForKey:@"Msg_type"] description],
				[[row objectForKey:@"Msg_text"] description]];
		else
			[tmp appendFormat:@"%@\t%@\n", [[row objectForKey:@"Table"] description],
				[[row objectForKey:@"Checksum"] description]];
	if ( [tmp length] )
	{
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
	
		[pb declareTypes:[NSArray arrayWithObjects: NSTabularTextPboardType, 
			NSStringPboardType, nil]
				   owner:nil];
	
		[pb setString:tmp forType:NSStringPboardType];
		[pb setString:tmp forType:NSTabularTextPboardType];
	}
}

#pragma mark -

/**
 * Dealloc
 */
- (void)dealloc
{

	// Unregister observers
	[prefs removeObserver:self forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:tableSourceInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:tableContentInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:customQueryInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:tableRelationsInstance forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:[SPQueryController sharedQueryController] forKeyPath:SPDisplayTableViewVerticalGridlines];
	[prefs removeObserver:tableSourceInstance forKeyPath:SPUseMonospacedFonts];
	[prefs removeObserver:[SPQueryController sharedQueryController] forKeyPath:SPUseMonospacedFonts];
	[prefs removeObserver:tableContentInstance forKeyPath:SPGlobalResultTableFont];
	[prefs removeObserver:[SPQueryController sharedQueryController] forKeyPath:SPConsoleEnableLogging];
	[prefs removeObserver:self forKeyPath:SPConsoleEnableLogging];
	if (processListController) [prefs removeObserver:processListController forKeyPath:SPDisplayTableViewVerticalGridlines];
	if (serverVariablesController) [prefs removeObserver:serverVariablesController forKeyPath:SPDisplayTableViewVerticalGridlines];

	[_encoding release];
	[allDatabases release];
	[allSystemDatabases release];
	[printWebView release];
	
	if (connectionController) [connectionController release];
	if (processListController) [processListController release];
	if (serverVariablesController) [serverVariablesController release];
	if (mySQLConnection) [mySQLConnection release];
	if (selectedDatabase) [selectedDatabase release];
	if (mySQLVersion) [mySQLVersion release];
	if (taskDrawTimer) [taskDrawTimer release];
	if (taskFadeAnimator) [taskFadeAnimator release];
	if (queryEditorInitString) [queryEditorInitString release];
	if (spfPreferences) [spfPreferences release];
	if (spfSession) [spfSession release];
	if (spfDocData) [spfDocData release];
	if (keyChainID) [keyChainID release];
	
	[super dealloc];
}

@end

@implementation TableDocument (PrivateAPI)

/**
 * Adds a new database.
 */
- (void)_addDatabase
{
	// This check is not necessary anymore as the add database button is now only enabled if the name field
	// has a length greater than zero. We'll leave it in just in case.
	if ([[databaseNameField stringValue] isEqualToString:@""]) {
		SPBeginAlertSheet(NSLocalizedString(@"Error", @"error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, NSLocalizedString(@"Database must have a name.", @"message of panel when no db name is given"));
		return;
	}
	
	NSString *createStatement = [NSString stringWithFormat:@"CREATE DATABASE %@", [[databaseNameField stringValue] backtickQuotedString]];
	
	// If there is an encoding selected other than the default we must specify it in CREATE DATABASE statement
	if ([databaseEncodingButton indexOfSelectedItem] > 0) {
		createStatement = [NSString stringWithFormat:@"%@ DEFAULT CHARACTER SET %@", createStatement, [[self mysqlEncodingFromDisplayEncoding:[databaseEncodingButton title]] backtickQuotedString]];
	}
	
	// Create the database
	[mySQLConnection queryString:createStatement];
	
	if ([mySQLConnection queryErrored]) {
		// An error occurred
		SPBeginAlertSheet(NSLocalizedString(@"Error", @"error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, [NSString stringWithFormat:NSLocalizedString(@"Couldn't create database.\nMySQL said: %@", @"message of panel when creation of db failed"), [mySQLConnection getLastErrorMessage]]);
		
		return;
	}
	
	// Error while selecting the new database (is this even possible?)
	if (![mySQLConnection selectDB:[databaseNameField stringValue]] ) {
		SPBeginAlertSheet(NSLocalizedString(@"Error", @"error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, [NSString stringWithFormat:NSLocalizedString(@"Unable to connect to database %@.\nBe sure that you have the necessary privileges.", @"message of panel when connection to db failed after selecting from popupbutton"), [databaseNameField stringValue]]);
		
		[self setDatabases:self];
		
		return;
	}
	
	// Select the new database
	if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
	
	
	selectedDatabase = [[NSString alloc] initWithString:[databaseNameField stringValue]];
	[self setDatabases:self];
	
	[tablesListInstance setConnection:mySQLConnection];
	[tableDumpInstance setConnection:mySQLConnection];
	
	[tableWindow setTitle:[self displaySPName]];
}

/**
 * Removes the current database.
 */
- (void)_removeDatabase
{
	// Drop the database from the server
	[mySQLConnection queryString:[NSString stringWithFormat:@"DROP DATABASE %@", [[self database] backtickQuotedString]]];
	
	if ([mySQLConnection queryErrored]) {
		// An error occurred
		[self performSelector:@selector(showErrorSheetWith:) 
				   withObject:[NSArray arrayWithObjects:NSLocalizedString(@"Error", @"error"),
							   [NSString stringWithFormat:NSLocalizedString(@"Couldn't remove database.\nMySQL said: %@", @"message of panel when removing db failed"), 
								[mySQLConnection getLastErrorMessage]],
							   nil] 
				   afterDelay:0.3];
		
		return;
	}

	// Remove db from navigator and completion list array,
	// do to threading we have to delete it from 'allDatabases' directly
	// before calling navigator
	[allDatabases removeObject:[self database]];
	// This only deletes the db and refreshes the navigator since nothing is changed
	// that's why we can run this on main thread
	[mySQLConnection queryDbStructureWithUserInfo:nil];

	// Delete was successful
	if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
	
	[self setDatabases:self];
	
	[tablesListInstance setConnection:mySQLConnection];
	[tableDumpInstance setConnection:mySQLConnection];
	
	[tableWindow setTitle:[self displaySPName]];

}

/**
 * Select the specified database and, optionally, table.
 */
- (void)_selectDatabaseAndItem:(NSDictionary *)selectionDetails
{
	NSAutoreleasePool *taskPool = [[NSAutoreleasePool alloc] init];
	NSString *targetDatabaseName = [selectionDetails objectForKey:@"database"];
	NSString *targetItemName = [selectionDetails objectForKey:@"item"];

	// Save existing scroll position and details, and ensure no duplicate entries are created as table list changes
	BOOL historyStateChanging = [spHistoryControllerInstance modifyingState];
	if (!historyStateChanging) {
		[spHistoryControllerInstance updateHistoryEntries];
		[spHistoryControllerInstance setModifyingState:YES];
	}

	if (![targetDatabaseName isEqualToString:selectedDatabase]) {

		// Attempt to select the specified database, and abort on failure
		if ([chooseDatabaseButton indexOfItemWithTitle:targetDatabaseName] == NSNotFound
			|| ![mySQLConnection selectDB:targetDatabaseName])
		{
			if ( [mySQLConnection isConnected] ) {
				SPBeginAlertSheet(NSLocalizedString(@"Error", @"error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, tableWindow, self, nil, nil, nil, [NSString stringWithFormat:NSLocalizedString(@"Unable to connect to database %@.\nBe sure that you have the necessary privileges.", @"message of panel when connection to db failed after selecting from popupbutton"), targetDatabaseName]);

				// Update the database list
				[self setDatabases:self];
			}

			[self endTask];
			[taskPool drain];
			return;
		}

		[[chooseDatabaseButton onMainThread] selectItemWithTitle:targetDatabaseName];
		if (selectedDatabase) [selectedDatabase release], selectedDatabase = nil;
		selectedDatabase = [[NSString alloc] initWithString:[chooseDatabaseButton titleOfSelectedItem]];

		// If the item has changed, clear the item selection for cleaner loading
		if (![targetItemName isEqualToString:[self table]]) {
			[[tablesListInstance onMainThread] setTableListSelectability:YES];
			[[[tablesListInstance valueForKey:@"tablesListView"] onMainThread] deselectAll:self];		
			[[tablesListInstance onMainThread] setTableListSelectability:NO];
		}
		
		// Set the connection of TablesList and TablesDump to reload tables in db
		[tablesListInstance setConnection:mySQLConnection];
		[tableDumpInstance setConnection:mySQLConnection];

		// Update the window title
		[[tableWindow onMainThread] setTitle:[self displaySPName]];

		// Add a history entry
		if (!historyStateChanging) {
			[spHistoryControllerInstance setModifyingState:NO];
			[spHistoryControllerInstance updateHistoryEntries];
		}

		// Set focus to table list filter field if visible
		// otherwise set focus to Table List view
		if ( [[tablesListInstance tables] count] > 20 )
			[[tableWindow onMainThread] makeFirstResponder:listFilterField];
		else
			[[tableWindow onMainThread] makeFirstResponder:[tablesListInstance valueForKeyPath:@"tablesListView"]];
	}

	// If a the table has changed, update the selection
	if (![targetItemName isEqualToString:[self table]]) {
		if (targetItemName) {
			[tablesListInstance selectItemWithName:targetItemName];
		} else {
			[[tablesListInstance onMainThread] setTableListSelectability:YES];
			[[[tablesListInstance valueForKey:@"tablesListView"] onMainThread] deselectAll:self];
			[[tablesListInstance onMainThread] setTableListSelectability:NO];
		}
	}

	// Query the structure of all databases in the background (mainly for completion)
	[NSThread detachNewThreadSelector:@selector(queryDbStructureWithUserInfo:) toTarget:mySQLConnection withObject:nil];

	[self endTask];
	[taskPool drain];
}
@end
