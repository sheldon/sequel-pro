//
//  $Id$
//
//  SPCopyTable.m
//  sequel-pro
//
//  Created by Stuart Glenn on Wed Apr 21 2004.
//  Changed by Lorenz Textor on Sat Nov 13 2004
//  Copyright (c) 2004 Stuart Glenn. All rights reserved.
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

#import <MCPKit/MCPKit.h>

#import "SPCopyTable.h"
#import "SPTableContent.h"
#import "SPTableTriggers.h"
#import "SPTableRelations.h"
#import "SPCustomQuery.h"
#import "SPDataStorage.h"
#import "SPTextAndLinkCell.h"
#import "SPTooltip.h"
#import "SPAlertSheets.h"
#import "SPBundleHTMLOutputController.h"

NSInteger MENU_EDIT_COPY             = 2001;
NSInteger MENU_EDIT_COPY_WITH_COLUMN = 2002;
NSInteger MENU_EDIT_COPY_AS_SQL      = 2003;

@implementation SPCopyTable


/**
 * Hold the selected range of the current table cell editor to be able to set this passed
 * selection in the field editor's editTextView
 */
@synthesize fieldEditorSelectedRange;

/**
 * Cell editing in SPCustomQuery or for views in SPTableContent
 */
- (BOOL) isCellEditingMode
{

	return ([[self delegate] isKindOfClass:[SPCustomQuery class]] 
		|| ([[self delegate] isKindOfClass:[SPTableContent class]] 
				&& [[self delegate] valueForKeyPath:@"tablesListInstance"] 
				&& [[[self delegate] valueForKeyPath:@"tablesListInstance"] tableType] == SPTableTypeView));

}

/**
 * Check if current edited cell represents a class other than a normal NSString
 * like pop-up menus for enum or set
 */
- (BOOL) isCellComplex
{

	return (![[self preparedCellAtColumn:[self editedColumn] row:[self editedRow]] isKindOfClass:[SPTextAndLinkCell class]]);

}

#pragma mark -

/**
 * Handles the general Copy action of selected rows in the table according to sender
 */
- (void) copy:(id)sender
{
	NSString *tmp = nil;

	if([sender tag] == MENU_EDIT_COPY_AS_SQL) {
		tmp = [self rowsAsSqlInsertsOnlySelectedRows:YES];
		if ( nil != tmp )
		{
			NSPasteboard *pb = [NSPasteboard generalPasteboard];

			[pb declareTypes:[NSArray arrayWithObjects: NSStringPboardType, nil]
					   owner:nil];

			[pb setString:tmp forType:NSStringPboardType];
		}
	} else {
		tmp = [self rowsAsTabStringWithHeaders:([sender tag] == MENU_EDIT_COPY_WITH_COLUMN) onlySelectedRows:YES];
		if ( nil != tmp )
		{
			NSPasteboard *pb = [NSPasteboard generalPasteboard];

			[pb declareTypes:[NSArray arrayWithObjects:
									NSTabularTextPboardType,
									NSStringPboardType,
									nil]
					   owner:nil];

			[pb setString:tmp forType:NSStringPboardType];
			[pb setString:tmp forType:NSTabularTextPboardType];
		}
	}
}

/**
 * Get selected rows a string of newline separated lines of tab separated fields
 * the value in each field is from the objects description method
 */
- (NSString *) rowsAsTabStringWithHeaders:(BOOL)withHeaders onlySelectedRows:(BOOL)onlySelected
{
	if (onlySelected && [self numberOfSelectedRows] == 0) return nil;

	NSIndexSet *selectedRows;
	if(onlySelected)
		selectedRows = [self selectedRowIndexes];
	else
		selectedRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [tableStorage count])];

	NSArray *columns = [self tableColumns];
	NSUInteger numColumns = [columns count];
	NSMutableString *result = [NSMutableString stringWithCapacity:2000];

	// Add the table headers if requested to do so
	if (withHeaders) {
		NSUInteger i;
		for( i = 0; i < numColumns; i++ ){
			if([result length])
				[result appendString:@"\t"];
			[result appendString:[[NSArrayObjectAtIndex(columns, i) headerCell] stringValue]];
		}
		[result appendString:@"\n"];
	}

	NSUInteger c;
	id cellData = nil;

	// Create an array of table column mappings for fast iteration
	NSUInteger *columnMappings = malloc(numColumns * sizeof(NSUInteger));
	for ( c = 0; c < numColumns; c++ )
		columnMappings[c] = [[NSArrayObjectAtIndex(columns, c) identifier] unsignedIntValue];

	// Loop through the rows, adding their descriptive contents
	NSUInteger rowIndex = [selectedRows firstIndex];
	NSString *nullString = [prefs objectForKey:SPNullValue];
	NSStringEncoding connectionEncoding = [mySQLConnection encoding];
	Class mcpGeometryData = [MCPGeometryData class];

	while ( rowIndex != NSNotFound )
	{
		for ( c = 0; c < numColumns; c++ ) {
			cellData = SPDataStorageObjectAtRowAndColumn(tableStorage, rowIndex, columnMappings[c]);

			// Copy the shown representation of the cell - custom NULL display strings, (not loaded),
			// and the string representation of any blobs or binary texts.
			if (cellData) {
				if ([cellData isNSNull])
					[result appendFormat:@"%@\t", nullString];
				else if ([cellData isSPNotLoaded])
					[result appendFormat:@"%@\t", NSLocalizedString(@"(not loaded)", @"value shown for hidden blob and text fields")];
				else if ([cellData isKindOfClass:[NSData class]]) {
					NSString *displayString = [[NSString alloc] initWithData:cellData encoding:[mySQLConnection stringEncoding]];
					if (!displayString) displayString = [[NSString alloc] initWithData:cellData encoding:NSASCIIStringEncoding];
					if (displayString) {
						[result appendFormat:@"%@\t", displayString];
						[displayString release];
					}
				}
				else if ([cellData isKindOfClass:mcpGeometryData]) {
					[result appendFormat:@"%@\t", [cellData wktString]];
				}
				else
					[result appendFormat:@"%@\t", [cellData description]];
			} else {
				[result appendString:@"\t"];
			}
		}

		// Remove the trailing tab and add the linebreak
		if ([result length]){
			[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
		}
		[result appendString:@"\n"];

		// Select the next row index
		rowIndex = [selectedRows indexGreaterThanIndex:rowIndex];
	}

	// Remove the trailing line end
	if ([result length]) {
		[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
	}

	free(columnMappings);

	return result;
}

/**
 * Get selected rows a string of newline separated lines of , separated fields wrapped into quotes
 * the value in each field is from the objects description method
 */
- (NSString *) rowsAsCsvStringWithHeaders:(BOOL)withHeaders onlySelectedRows:(BOOL)onlySelected
{
	if (onlySelected && [self numberOfSelectedRows] == 0) return nil;

	NSIndexSet *selectedRows;
	if(onlySelected)
		selectedRows = [self selectedRowIndexes];
	else
		selectedRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [tableStorage count])];

	NSArray *columns = [self tableColumns];
	NSUInteger numColumns = [columns count];
	NSMutableString *result = [NSMutableString stringWithCapacity:2000];

	// Add the table headers if requested to do so
	if (withHeaders) {
		NSUInteger i;
		for( i = 0; i < numColumns; i++ ){
			if([result length])
				[result appendString:@","];
			[result appendFormat:@"\"%@\"", [[[NSArrayObjectAtIndex(columns, i) headerCell] stringValue] stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
		}
		[result appendString:@"\n"];
	}

	NSUInteger c;
	id cellData = nil;

	// Create an array of table column mappings for fast iteration
	NSUInteger *columnMappings = malloc(numColumns * sizeof(NSUInteger));
	for ( c = 0; c < numColumns; c++ )
		columnMappings[c] = [[NSArrayObjectAtIndex(columns, c) identifier] unsignedIntValue];

	// Loop through the rows, adding their descriptive contents
	NSUInteger rowIndex = [selectedRows firstIndex];
	NSString *nullString = [prefs objectForKey:SPNullValue];
	NSStringEncoding connectionEncoding = [mySQLConnection encoding];
	Class mcpGeometryData = [MCPGeometryData class];

	while ( rowIndex != NSNotFound )
	{
		for ( c = 0; c < numColumns; c++ ) {
			cellData = SPDataStorageObjectAtRowAndColumn(tableStorage, rowIndex, columnMappings[c]);

			// Copy the shown representation of the cell - custom NULL display strings, (not loaded),
			// and the string representation of any blobs or binary texts.
			if (cellData) {
				if ([cellData isNSNull])
					[result appendFormat:@"\"%@\",", nullString];
				else if ([cellData isSPNotLoaded])
					[result appendFormat:@"\"%@\",", NSLocalizedString(@"(not loaded)", @"value shown for hidden blob and text fields")];
				else if ([cellData isKindOfClass:[NSData class]]) {
					NSString *displayString = [[NSString alloc] initWithData:cellData encoding:[mySQLConnection stringEncoding]];
					if (!displayString) displayString = [[NSString alloc] initWithData:cellData encoding:NSASCIIStringEncoding];
					if (displayString) {
						[result appendFormat:@"\"%@\",", [displayString stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
						[displayString release];
					}
				}
				else if ([cellData isKindOfClass:mcpGeometryData]) {
					[result appendFormat:@"\"%@\",", [cellData wktString]];
				}
				else
					[result appendFormat:@"\"%@\",", [[cellData description] stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
			} else {
				[result appendString:@","];
			}
		}

		// Remove the trailing tab and add the linebreak
		if ([result length]){
			[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
		}
		[result appendString:@"\n"];

		// Select the next row index
		rowIndex = [selectedRows indexGreaterThanIndex:rowIndex];
	}

	// Remove the trailing line end
	if ([result length]) {
		[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
	}

	free(columnMappings);

	return result;
}

/*
 * Return selected rows as SQL INSERT INTO `foo` VALUES (baz) string.
 * If no selected table name is given `<table>` will be used instead.
 */
- (NSString *) rowsAsSqlInsertsOnlySelectedRows:(BOOL)onlySelected
{

	if (onlySelected && [self numberOfSelectedRows] == 0) return nil;

	NSIndexSet *selectedRows;
	if(onlySelected)
		selectedRows = [self selectedRowIndexes];
	else
		selectedRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, [tableStorage count])];

	NSArray *columns         = [self tableColumns];
	NSUInteger numColumns    = [columns count];

	NSMutableString *value   = [NSMutableString stringWithCapacity:10];

	id cellData = nil;

	NSUInteger rowCounter = 0;
	NSUInteger penultimateRowIndex = [selectedRows count];
	NSUInteger c;
	NSUInteger valueLength = 0;

	NSMutableString *result = [NSMutableString stringWithCapacity:2000];

	// Create an array of table column names
	NSMutableArray *tbHeader = [NSMutableArray arrayWithCapacity:numColumns];
	for (id enumObj in columns) {
		[tbHeader addObject:[[enumObj headerCell] stringValue]];
	}

	// Create arrays of table column mappings and types for fast iteration
	NSUInteger *columnMappings = malloc(numColumns * sizeof(NSUInteger));
	NSUInteger *columnTypes = malloc(numColumns * sizeof(NSUInteger));
	for ( c = 0; c < numColumns; c++) {
		columnMappings[c] = [[NSArrayObjectAtIndex(columns, c) identifier] unsignedIntValue];

		NSString *t = [NSArrayObjectAtIndex(columnDefinitions, columnMappings[c]) objectForKey:@"typegrouping"];

		// Numeric data
		if ([t isEqualToString:@"bit"] || [t isEqualToString:@"integer"] || [t isEqualToString:@"float"])
			columnTypes[c] = 0;

		// Blob data or long text data
		else if ([t isEqualToString:@"blobdata"] || [t isEqualToString:@"textdata"])
			columnTypes[c] = 2;

		// GEOMETRY data
		else if ([t isEqualToString:@"geometry"])
			columnTypes[c] = 3;

		// Default to strings
		else
			columnTypes[c] = 1;
	}

	// Begin the SQL string
	[result appendFormat:@"INSERT INTO %@ (%@)\nVALUES\n",
		[(selectedTable == nil) ? @"<table>" : selectedTable backtickQuotedString], [tbHeader componentsJoinedAndBacktickQuoted]];

	NSUInteger rowIndex = [selectedRows firstIndex];
	Class spTableContentClass = [SPTableContent class];
	Class nsDataClass = [NSData class];
	while ( rowIndex != NSNotFound )
	{
		[value appendString:@"\t("];
		cellData = nil;
		rowCounter++;
		for ( c = 0; c < numColumns; c++ )
		{
			cellData = SPDataStorageObjectAtRowAndColumn(tableStorage, rowIndex, columnMappings[c]);

			// If the data is not loaded, attempt to fetch the value
			if ([cellData isSPNotLoaded] && [[self delegate] isKindOfClass:spTableContentClass]) {

				// Abort if no table name given, not table content, or if there are no indices on this table
				if (!selectedTable || ![[self delegate] isKindOfClass:spTableContentClass] || ![[tableInstance argumentForRow:rowIndex] length]) {
					NSBeep();
					free(columnMappings);
					free(columnTypes);
					return nil;
				}

				// Use the argumentForRow to retrieve the missing information
				// TODO - this could be preloaded for all selected rows rather than cell-by-cell
				cellData = [mySQLConnection getFirstFieldFromQuery:
							[NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@",
								[NSArrayObjectAtIndex(tbHeader, columnMappings[c]) backtickQuotedString],
								[selectedTable backtickQuotedString],
								[tableInstance argumentForRow:rowIndex]]];
			}

			// Check for NULL value
			if ([cellData isNSNull]) {
				[value appendString:@"NULL, "];
				continue;

			} else if (cellData) {

				// Check column type and insert the data accordingly
				switch(columnTypes[c]) {

					// Convert numeric types to unquoted strings
					case 0:
						[value appendFormat:@"%@, ", [cellData description]];
						break;

					// Quote string, text and blob types appropriately
					case 1:
					case 2:
						if ([cellData isKindOfClass:nsDataClass]) {
							[value appendFormat:@"X'%@', ", [mySQLConnection prepareBinaryData:cellData]];
						} else {
							[value appendFormat:@"'%@', ", [mySQLConnection prepareString:[cellData description]]];
						}
						break;

					// GEOMETRY
					case 3:
						[value appendFormat:@"X'%@', ", [mySQLConnection prepareBinaryData:[cellData data]]];
						break;
					// Unhandled cases - abort
					default:
						NSBeep();
						free(columnMappings);
						free(columnTypes);
						return nil;
				}

			// If nil is encountered, abort
			} else {
				NSBeep();
				free(columnMappings);
				free(columnTypes);
				return nil;
			}
		}

		// Remove the trailing ', ' from the query
		if ( [value length] > 2 )
			[value deleteCharactersInRange:NSMakeRange([value length]-2, 2)];

		valueLength += [value length];

		// Close this VALUES group and set up the next one if appropriate
		if ( rowCounter != penultimateRowIndex ) {

			// Add a new INSERT starter command every ~250k of data.
			if ( valueLength > 250000 ) {
				[result appendFormat:@"%@);\n\nINSERT INTO %@ (%@)\nVALUES\n",
						value,
						[(selectedTable == nil) ? @"<table>" : selectedTable backtickQuotedString],
						[tbHeader componentsJoinedAndBacktickQuoted]];
				[value setString:@""];
				valueLength = 0;
			} else {
				[value appendString:@"),\n"];
			}

		} else {
			[value appendString:@"),\n"];
			[result appendString:value];
		}

		// Get the next selected row index
		rowIndex = [selectedRows indexGreaterThanIndex:rowIndex];

	}

	// Remove the trailing ",\n" from the query string
	if ( [result length] > 3 )
		[result deleteCharactersInRange:NSMakeRange([result length]-2, 2)];

	[result appendString:@";\n"];

	free(columnMappings);
	free(columnTypes);

	return result;
}

/**
 * Allow for drag-n-drop out of the application as a copy
 */
- (NSUInteger) draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
	return NSDragOperationCopy;
}

/**
 * Get dragged rows a string of newline separated lines of tab separated fields
 * the value in each field is from the objects description method
 */
- (NSString *) draggedRowsAsTabString
{
	NSArray *columns = [self tableColumns];
	NSUInteger numColumns = [columns count];
	NSIndexSet *selectedRows = [self selectedRowIndexes];

	NSMutableString *result = [NSMutableString stringWithCapacity:2000];
	NSUInteger c;
	id cellData = nil;

	// Create an array of table column mappings for fast iteration
	NSUInteger *columnMappings = malloc(numColumns * sizeof(NSUInteger));
	for ( c = 0; c < numColumns; c++ )
		columnMappings[c] = [[NSArrayObjectAtIndex(columns, c) identifier] unsignedIntValue];

	// Loop through the rows, adding their descriptive contents
	NSUInteger rowIndex = [selectedRows firstIndex];
	NSString *nullString = [prefs objectForKey:SPNullValue];
	Class nsDataClass = [NSData class];
	Class mcpGeometryData = [MCPGeometryData class];
	NSStringEncoding connectionEncoding = [mySQLConnection stringEncoding];
	while ( rowIndex != NSNotFound )
	{
		for ( c = 0; c < numColumns; c++ ) {
			cellData = SPDataStorageObjectAtRowAndColumn(tableStorage, rowIndex, columnMappings[c]);

			// Copy the shown representation of the cell - custom NULL display strings, (not loaded),
			// and the string representation of any blobs or binary texts.
			if (cellData) {
				if ([cellData isNSNull])
					[result appendFormat:@"%@\t", nullString];
				else if ([cellData isSPNotLoaded])
					[result appendFormat:@"%@\t", NSLocalizedString(@"(not loaded)", @"value shown for hidden blob and text fields")];
				else if ([cellData isKindOfClass:nsDataClass]) {
					NSString *displayString = [[NSString alloc] initWithData:cellData encoding:connectionEncoding];
					if (!displayString) displayString = [[NSString alloc] initWithData:cellData encoding:NSASCIIStringEncoding];
					if (displayString) {
						[result appendString:displayString];
						[displayString release];
					}
				}
				else if ([cellData isKindOfClass:mcpGeometryData]) {
					[result appendFormat:@"%@\t", [cellData wktString]];
				} else
					[result appendFormat:@"%@\t", [cellData description]];
			} else {
				[result appendString:@"\t"];
			}
		}

		if ([result length]) {
			[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
		}

		[result appendString:@"\n"];

		// Retrieve the next selected row index
		rowIndex = [selectedRows indexGreaterThanIndex:rowIndex];
	}

	// Trim the trailing line ending
	if ([result length]) {
		[result deleteCharactersInRange:NSMakeRange([result length]-1, 1)];
	}

	free(columnMappings);

	return result;
}

#pragma mark -

/**
 * Init self with data coming from the table content view. Mainly used for copying data properly.
 */
- (void) setTableInstance:(id)anInstance withTableData:(SPDataStorage *)theTableStorage withColumns:(NSArray *)columnDefs withTableName:(NSString *)aTableName withConnection:(id)aMySqlConnection
{
	selectedTable     = aTableName;
	mySQLConnection   = aMySqlConnection;
	tableInstance     = anInstance;
	tableStorage	  = theTableStorage;

	if (columnDefinitions) [columnDefinitions release], columnDefinitions = nil;
	columnDefinitions = [[NSArray alloc] initWithArray:columnDefs];
}

/*
 * Update the table storage location if necessary.
 */
- (void) setTableData:(SPDataStorage *)theTableStorage
{
	tableStorage = theTableStorage;
}

#pragma mark -

/**
 * Autodetect column widths for a specified font.
 */
- (NSDictionary *) autodetectColumnWidths
{
	NSMutableDictionary *columnWidths = [NSMutableDictionary dictionaryWithCapacity:[columnDefinitions count]];
	NSUInteger columnWidth;
	NSUInteger allColumnWidths = 0;

	for (NSDictionary *columnDefinition in columnDefinitions) {
		if ([[NSThread currentThread] isCancelled]) return nil;

		columnWidth = [self autodetectWidthForColumnDefinition:columnDefinition maxRows:100];
		[columnWidths setObject:[NSNumber numberWithUnsignedInteger:columnWidth] forKey:[columnDefinition objectForKey:@"datacolumnindex"]];
		allColumnWidths += columnWidth;
	}

	// Compare the column widths to the table width.  If wider, narrow down wide columns as necessary
	if (allColumnWidths > [self bounds].size.width) {
		NSUInteger availableWidthToReduce = 0;

		// Look for columns that are wider than the multi-column max
		for (NSString *columnIdentifier in columnWidths) {
			columnWidth = [[columnWidths objectForKey:columnIdentifier] unsignedIntegerValue];
			if (columnWidth > SP_MAX_CELL_WIDTH_MULTICOLUMN) availableWidthToReduce += columnWidth - SP_MAX_CELL_WIDTH_MULTICOLUMN;
		}

		// Determine how much width can be reduced
		NSUInteger widthToReduce = allColumnWidths - [self bounds].size.width;
		if (availableWidthToReduce < widthToReduce) widthToReduce = availableWidthToReduce;

		// Proportionally decrease the column sizes
		if (widthToReduce) {
			NSArray *columnIdentifiers = [columnWidths allKeys];
			for (NSString *columnIdentifier in columnIdentifiers) {
				columnWidth = [[columnWidths objectForKey:columnIdentifier] unsignedIntegerValue];
				if (columnWidth > SP_MAX_CELL_WIDTH_MULTICOLUMN) {
					columnWidth -= ceil((double)(columnWidth - SP_MAX_CELL_WIDTH_MULTICOLUMN) / availableWidthToReduce * widthToReduce);
					[columnWidths setObject:[NSNumber numberWithUnsignedInteger:columnWidth] forKey:columnIdentifier];
				}
			}
		}
	}

	return columnWidths;
}

/**
 * Autodetect the column width for a specified column - derived from the supplied
 * column definition, using the stored data and the specified font.
 */
- (NSUInteger)autodetectWidthForColumnDefinition:(NSDictionary *)columnDefinition maxRows:(NSUInteger)rowsToCheck
{
	CGFloat columnBaseWidth;
	id contentString;
	NSUInteger cellWidth, maxCellWidth, i;
	NSRange linebreakRange;
	double rowStep;
	NSFont *tableFont = [NSUnarchiver unarchiveObjectWithData:[prefs dataForKey:SPGlobalResultTableFont]];
	NSUInteger columnIndex = [[columnDefinition objectForKey:@"datacolumnindex"] unsignedIntegerValue];
	NSDictionary *stringAttributes = [NSDictionary dictionaryWithObject:tableFont forKey:NSFontAttributeName];
	Class mcpGeometryData = [MCPGeometryData class];

	// Check the number of rows available to check, sampling every n rows
	if ([tableStorage count] < rowsToCheck)
		rowStep = 1;
	else
		rowStep = floor([tableStorage count] / rowsToCheck);

	rowsToCheck = [tableStorage count];

	// Set a default padding for this column
	columnBaseWidth = 24;

	// Iterate through the data store rows, checking widths
	maxCellWidth = 0;
	for (i = 0; i < rowsToCheck; i += rowStep) {

		// Retrieve the cell's content
		contentString = [tableStorage cellDataAtRow:i column:columnIndex];

		// Get WKT string out of the MCPGeometryData for calculation
		if ([contentString isKindOfClass:mcpGeometryData])
			contentString = [contentString wktString];

		// Replace NULLs with their placeholder string
		else if ([contentString isNSNull]) {
			contentString = [prefs objectForKey:SPNullValue];

		// Same for cells for which loading has been deferred - likely blobs
		} else if ([contentString isSPNotLoaded]) {
			contentString = NSLocalizedString(@"(not loaded)", @"value shown for hidden blob and text fields");

		} else {

			// Otherwise, ensure the cell is represented as a short string
			if ([contentString isKindOfClass:[NSData class]]) {
				contentString = [contentString shortStringRepresentationUsingEncoding:[mySQLConnection stringEncoding]];
			} else if ([contentString length] > 500) {
				contentString = [contentString substringToIndex:500];
			}

			// If any linebreaks are present, use only the visible part of the string
			linebreakRange = [contentString rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
			if (linebreakRange.location != NSNotFound) {
				contentString = [contentString substringToIndex:linebreakRange.location];
			}
		}

		// Calculate the width, using it if it's higher than the current stored width
		cellWidth = [contentString sizeWithAttributes:stringAttributes].width;
		if (cellWidth > maxCellWidth) maxCellWidth = cellWidth;
		if (maxCellWidth > SP_MAX_CELL_WIDTH) {
			maxCellWidth = SP_MAX_CELL_WIDTH;
			break;
		}
	}

	// If the column has a foreign key link, expand the width; and also for enums
	if ([columnDefinition objectForKey:@"foreignkeyreference"]) {
		maxCellWidth += 18;
	} else if ([[columnDefinition objectForKey:@"typegrouping"] isEqualToString:@"enum"]) {
		maxCellWidth += 8;
	}

	// Add the padding
	maxCellWidth += columnBaseWidth;

	// If the header width is wider than this expanded width, use it instead
	cellWidth = [[columnDefinition objectForKey:@"name"] sizeWithAttributes:[NSDictionary dictionaryWithObject:[NSFont labelFontOfSize:[NSFont smallSystemFontSize]] forKey:NSFontAttributeName]].width;
	if (cellWidth + 10 > maxCellWidth) maxCellWidth = cellWidth + 10;

	return maxCellWidth;
}

#pragma mark -

- (NSMenu *)menuForEvent:(NSEvent *)event 
{

	NSMenu *menu = [self menu];

	if(![[self delegate] isKindOfClass:[SPCustomQuery class]] && ![[self delegate] isKindOfClass:[SPTableContent class]]) return menu;

	[[NSApp delegate] reloadBundles:self];

	// Remove 'Bundles' sub menu and separator
	NSMenuItem *bItem = [menu itemWithTag:10000000];
	if(bItem) {
		NSInteger sepIndex = [menu indexOfItem:bItem]-1;
		[menu removeItemAtIndex:sepIndex];
		[menu removeItem:bItem];
	}

	NSArray *bundleCategories = [[NSApp delegate] bundleCategoriesForScope:SPBundleScopeDataTable];
	NSArray *bundleItems = [[NSApp delegate] bundleItemsForScope:SPBundleScopeDataTable];

	// Add 'Bundles' sub menu
	if(bundleItems && [bundleItems count]) {
		[menu addItem:[NSMenuItem separatorItem]];

		NSMenu *bundleMenu = [[[NSMenu alloc] init] autorelease];
		NSMenuItem *bundleSubMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Bundles", @"bundles menu item label") action:nil keyEquivalent:@""];
		[bundleSubMenuItem setTag:10000000];

		[menu addItem:bundleSubMenuItem];
		[menu setSubmenu:bundleMenu forItem:bundleSubMenuItem];

		NSMutableArray *categorySubMenus = [NSMutableArray array];
		NSMutableArray *categoryMenus = [NSMutableArray array];
		if([bundleCategories count]) {
			for(NSString* title in bundleCategories) {
				[categorySubMenus addObject:[[[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""] autorelease]];
				[categoryMenus addObject:[[[NSMenu alloc] init] autorelease]];
				[bundleMenu addItem:[categorySubMenus lastObject]];
				[bundleMenu setSubmenu:[categoryMenus lastObject] forItem:[categorySubMenus lastObject]];
			}
		}

		NSInteger i = 0;
		for(NSDictionary *item in bundleItems) {

			NSString *keyEq;
			if([item objectForKey:SPBundleFileKeyEquivalentKey])
				keyEq = [[item objectForKey:SPBundleFileKeyEquivalentKey] objectAtIndex:0];
			else
				keyEq = @"";

			NSMenuItem *mItem = [[[NSMenuItem alloc] initWithTitle:[item objectForKey:SPBundleInternLabelKey] action:@selector(executeBundleItemForDataTable:) keyEquivalent:keyEq] autorelease];

			if([keyEq length])
				[mItem setKeyEquivalentModifierMask:[[[item objectForKey:SPBundleFileKeyEquivalentKey] objectAtIndex:1] intValue]];

			if([item objectForKey:SPBundleFileTooltipKey])
				[mItem setToolTip:[item objectForKey:SPBundleFileTooltipKey]];

			[mItem setTag:1000000 + i++];

			if([item objectForKey:SPBundleFileCategoryKey]) {
				[[categoryMenus objectAtIndex:[bundleCategories indexOfObject:[item objectForKey:SPBundleFileCategoryKey]]] addItem:mItem];
			} else {
				[bundleMenu addItem:mItem];
			}
		}

		[bundleSubMenuItem release];

	}

	return menu;

}

- (void)selectTableRows:(NSArray*)rowIndices
{

	if(!rowIndices || ![rowIndices count]) return;

	NSMutableIndexSet *selection = [NSMutableIndexSet indexSet];
	NSInteger rows = [[self delegate] numberOfRowsInTableView:self];
	NSUInteger i;
	if(rows > 0) {
		for(NSString* idx in rowIndices) {
			i = [idx longLongValue];
			if(i >= 0 && i < rows)
				[selection addIndex:i];
		}

		[self selectRowIndexes:selection byExtendingSelection:NO];
	}

}

- (IBAction)executeBundleItemForDataTable:(id)sender
{
	NSInteger idx = [sender tag] - 1000000;
	NSString *infoPath = nil;
	NSArray *bundleItems = [[NSApp delegate] bundleItemsForScope:SPBundleScopeDataTable];
	if(idx >=0 && idx < [bundleItems count]) {
		infoPath = [[bundleItems objectAtIndex:idx] objectForKey:SPBundleInternPathToFileKey];
	} else {
		if([sender tag] == 0 && [[sender toolTip] length]) {
			infoPath = [sender toolTip];
		}
	}

	if(!infoPath) {
		NSBeep();
		return;
	}

	NSError *readError = nil;
	NSString *convError = nil;
	NSPropertyListFormat format;
	NSDictionary *cmdData = nil;
	NSData *pData = [NSData dataWithContentsOfFile:infoPath options:NSUncachedRead error:&readError];

	cmdData = [[NSPropertyListSerialization propertyListFromData:pData 
			mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&convError] retain];

	if(!cmdData || readError != nil || [convError length] || !(format == NSPropertyListXMLFormat_v1_0 || format == NSPropertyListBinaryFormat_v1_0)) {
		NSLog(@"“%@” file couldn't be read.", infoPath);
		NSBeep();
		if (cmdData) [cmdData release];
		return;
	} else {
		if([cmdData objectForKey:SPBundleFileCommandKey] && [[cmdData objectForKey:SPBundleFileCommandKey] length]) {

			NSString *cmd = [cmdData objectForKey:SPBundleFileCommandKey];
			NSString *inputAction = @"";
			NSString *inputFallBackAction = @"";
			NSError *err = nil;
			NSString *bundleInputFilePath = [NSString stringWithFormat:@"%@_%@", SPBundleTaskInputFilePath, [NSString stringWithNewUUID]];

			[[NSFileManager defaultManager] removeItemAtPath:bundleInputFilePath error:nil];

			if([cmdData objectForKey:SPBundleFileInputSourceKey])
				inputAction = [[cmdData objectForKey:SPBundleFileInputSourceKey] lowercaseString];
			if([cmdData objectForKey:SPBundleFileInputSourceFallBackKey])
				inputFallBackAction = [[cmdData objectForKey:SPBundleFileInputSourceFallBackKey] lowercaseString];

			NSMutableDictionary *env = [NSMutableDictionary dictionary];
			[env setObject:[infoPath stringByDeletingLastPathComponent] forKey:@"SP_BUNDLE_PATH"];
			[env setObject:bundleInputFilePath forKey:@"SP_BUNDLE_INPUT_FILE"];

			if([[self delegate] respondsToSelector:@selector(usedQuery)] && [[self delegate] usedQuery])
				[env setObject:[[self delegate] usedQuery] forKey:@"SP_USED_QUERY_FOR_TABLE"];

			if([self numberOfSelectedRows]) {
				NSMutableArray *sel = [NSMutableArray array];
				NSIndexSet *selectedRows = [self selectedRowIndexes];
				NSUInteger rowIndex = [selectedRows firstIndex];
				while ( rowIndex != NSNotFound ) {
					[sel addObject:[NSString stringWithFormat:@"%ld", rowIndex]];
					rowIndex = [selectedRows indexGreaterThanIndex:rowIndex];
				}
				[env setObject:[sel componentsJoinedByString:@"\t"] forKey:@"SP_SELECTED_ROW_INDICES"];
			}

			NSError *inputFileError = nil;
			NSString *input = @"";
			if([inputAction isEqualToString:SPBundleInputSourceSelectedTableRowsAsTab]) {
				input = [self rowsAsTabStringWithHeaders:YES onlySelectedRows:YES];
			}
			else if([inputAction isEqualToString:SPBundleInputSourceSelectedTableRowsAsCsv]) {
				input = [self rowsAsCsvStringWithHeaders:YES onlySelectedRows:YES];
			}
			else if([inputAction isEqualToString:SPBundleInputSourceSelectedTableRowsAsSqlInsert]) {
				input = [self rowsAsSqlInsertsOnlySelectedRows:YES];
			}
			else if([inputAction isEqualToString:SPBundleInputSourceTableRowsAsTab]) {
				input = [self rowsAsTabStringWithHeaders:YES onlySelectedRows:NO];
			}
			else if([inputAction isEqualToString:SPBundleInputSourceTableRowsAsCsv]) {
				input = [self rowsAsCsvStringWithHeaders:YES onlySelectedRows:NO];
			}
			else if([inputAction isEqualToString:SPBundleInputSourceTableRowsAsSqlInsert]) {
				input = [self rowsAsSqlInsertsOnlySelectedRows:NO];
			}
			
			if(input == nil) input = @"";
			[input writeToFile:bundleInputFilePath
					  atomically:YES
						encoding:NSUTF8StringEncoding
						   error:&inputFileError];
			
			if(inputFileError != nil) {
				NSString *errorMessage  = [inputFileError localizedDescription];
				SPBeginAlertSheet(NSLocalizedString(@"Bundle Error", @"bundle error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, [self window], self, nil, nil,
								  [NSString stringWithFormat:@"%@ “%@”:\n%@", NSLocalizedString(@"Error for", @"error for message"), [cmdData objectForKey:@"name"], errorMessage]);
				if (cmdData) [cmdData release];
				return;
			}

			NSString *output = [cmd runBashCommandWithEnvironment:env atCurrentDirectoryPath:nil callerDocument:[[NSApp delegate] frontDocument] withName:([cmdData objectForKey:SPBundleFileNameKey])?[cmdData objectForKey:SPBundleFileNameKey]:@"" error:&err];

			[[NSFileManager defaultManager] removeItemAtPath:bundleInputFilePath error:nil];

			if(err == nil && output) {
				if([cmdData objectForKey:SPBundleFileOutputActionKey] && [[cmdData objectForKey:SPBundleFileOutputActionKey] length] 
						&& ![[cmdData objectForKey:SPBundleFileOutputActionKey] isEqualToString:SPBundleOutputActionNone]) {
					NSString *action = [[cmdData objectForKey:SPBundleFileOutputActionKey] lowercaseString];
					NSPoint pos = [NSEvent mouseLocation];
					pos.y -= 16;

					if([action isEqualToString:SPBundleOutputActionShowAsTextTooltip]) {
						[SPTooltip showWithObject:output atLocation:pos];
					}

					else if([action isEqualToString:SPBundleOutputActionShowAsHTMLTooltip]) {
						[SPTooltip showWithObject:output atLocation:pos ofType:@"html"];
					}

					else if([action isEqualToString:SPBundleOutputActionShowAsHTML]) {
						BOOL correspondingWindowFound = NO;
						for(id win in [NSApp windows]) {
							if([[win delegate] isKindOfClass:[SPBundleHTMLOutputController class]]) {
								if([[[win delegate] windowUUID] isEqualToString:[cmdData objectForKey:SPBundleFileUUIDKey]]) {
									correspondingWindowFound = YES;
									[[win delegate] displayHTMLContent:output withOptions:nil];
									break;
								}
							}
						}
						if(!correspondingWindowFound) {
							SPBundleHTMLOutputController *c = [[SPBundleHTMLOutputController alloc] init];
							[c setWindowUUID:[cmdData objectForKey:SPBundleFileUUIDKey]];
							[c displayHTMLContent:output withOptions:nil];
						}
					}
				}
			} else {
				NSString *errorMessage  = [err localizedDescription];
				SPBeginAlertSheet(NSLocalizedString(@"BASH Error", @"bash error"), NSLocalizedString(@"OK", @"OK button"), nil, nil, [self window], self, nil, nil,
								  [NSString stringWithFormat:@"%@ “%@”:\n%@", NSLocalizedString(@"Error for", @"error for message"), [cmdData objectForKey:@"name"], errorMessage]);
			}

		}

		if (cmdData) [cmdData release];

	}

}

/**
 * Only have the copy menu item enabled when row(s) are selected in
 * supported tables.
 */
- (BOOL) validateMenuItem:(NSMenuItem*)anItem
{
	NSInteger menuItemTag = [anItem tag];

	// Don't validate anything other than the copy commands
	if (menuItemTag != MENU_EDIT_COPY && menuItemTag != MENU_EDIT_COPY_WITH_COLUMN && menuItemTag != MENU_EDIT_COPY_AS_SQL) {
		return YES;
	}

	// Don't enable menus for relations or triggers - no action to take yet
	if ([[self delegate] isKindOfClass:[SPTableRelations class]] || [[self delegate] isKindOfClass:[SPTableTriggers class]]) {
		return NO;
	}

	// Enable the Copy [with column names] commands if a row is selected
	if (menuItemTag == MENU_EDIT_COPY || menuItemTag == MENU_EDIT_COPY_WITH_COLUMN) {
		return ([self numberOfSelectedRows] > 0);
	}

	// Enable the Copy as SQL commands if rows are selected and column definitions are available
	if (menuItemTag == MENU_EDIT_COPY_AS_SQL) {
		return (columnDefinitions != nil && [self numberOfSelectedRows] > 0);
	}

	return NO;
}

/**
 * Trap the enter, escape, tab and arrow keys, overriding default behaviour and continuing/ending editing,
 * only within the current row.
 */
- (BOOL) control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{

	NSUInteger row, column;

	row = [self editedRow];
	column = [self editedColumn];

	// Trap tab key
	// -- for handling of blob fields and to check if it's editable look at [[self delegate] control:textShouldBeginEditing:]
	if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(insertTab:)] )
	{
		[[control window] makeFirstResponder:control];

		// Save the current line if it's the last field in the table
		if ( [self numberOfColumns] - 1 == column ) {
			if([[self delegate] respondsToSelector:@selector(addRowToDB)])
				[[self delegate] addRowToDB];
			[[self window] makeFirstResponder:self];
		} else {
			// Select the next field for editing
			[self editColumn:column+1 row:row withEvent:nil select:YES];
		}

		return YES;
	}

	// Trap shift-tab key
	else if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(insertBacktab:)] )
	{
		[[control window] makeFirstResponder:control];

		// Save the current line if it's the last field in the table
		if ( column < 1 ) {
			if([[self delegate] respondsToSelector:@selector(addRowToDB)])
				[[self delegate] addRowToDB];
			[[self window] makeFirstResponder:self];
		} else {
			// Select the previous field for editing
			[self editColumn:column-1 row:row withEvent:nil select:YES];
		}

		return YES;
	}

	// Trap enter key
	else if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(insertNewline:)] )
	{
		// If enum field is edited RETURN selects the new value instead of saving the entire row
		if([self isCellComplex])
			return YES;

		[[control window] makeFirstResponder:control];
		if([[self delegate] isKindOfClass:[SPTableContent class]] && ![self isCellEditingMode] && [[self delegate] respondsToSelector:@selector(addRowToDB)])
			[[self delegate] addRowToDB];
		return YES;

	}

	// Trap down arrow key
	else if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(moveDown:)] )
	{

		// If enum field is edited ARROW key navigates through the popup list
		if([self isCellComplex])
			return NO;

		NSUInteger newRow = row+1;
		if (newRow>=[[self delegate] numberOfRowsInTableView:self]) return YES; //check if we're already at the end of the list

		[[control window] makeFirstResponder:control];
		if([[self delegate] isKindOfClass:[SPTableContent class]] && ![self isCellEditingMode] && [[self delegate] respondsToSelector:@selector(addRowToDB)])
			[[self delegate] addRowToDB];

		if (newRow>=[[self delegate] numberOfRowsInTableView:self]) return YES; //check again. addRowToDB could reload the table and change the number of rows
		if (tableStorage && column>=[tableStorage columnCount]) return YES;     //the column count could change too

		[self selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
		[self editColumn:column row:newRow withEvent:nil select:YES];
		return YES;
	}

	// Trap up arrow key
	else if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(moveUp:)] )
	{

		// If enum field is edited ARROW key navigates through the popup list
		if([self isCellComplex])
			return NO;

		if (row==0) return YES; //already at the beginning of the list
		NSUInteger newRow = row-1;

		[[control window] makeFirstResponder:control];
		if([[self delegate] isKindOfClass:[SPTableContent class]] && ![self isCellEditingMode] && [[self delegate] respondsToSelector:@selector(addRowToDB)])
			[[self delegate] addRowToDB];

		if (newRow>=[[self delegate] numberOfRowsInTableView:self]) return YES; // addRowToDB could reload the table and change the number of rows
		if (tableStorage && column>=[tableStorage columnCount]) return YES;     //the column count could change too

		[self selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
		[self editColumn:column row:newRow withEvent:nil select:YES];
		return YES;
	}

	return NO;
}

- (void) keyDown:(NSEvent *)theEvent
{

	// RETURN or ENTER invoke editing mode for selected row
	// by calling tableView:shouldEditTableColumn: to validate

	if([self numberOfSelectedRows] == 1 && ([theEvent keyCode] == 36 || [theEvent keyCode] == 76)) {
		[self editColumn:0 row:[self selectedRow] withEvent:nil select:YES];
		return;
	}
	
	// Check if ESCAPE is hit and use it to cancel row editing if supported
	if ([theEvent keyCode] == 53 && [[self delegate] respondsToSelector:@selector(cancelRowEditing)])
	{
		if ([[self delegate] cancelRowEditing]) return;
	}

	else if ([theEvent keyCode] == 48 && ([[self delegate] isKindOfClass:[SPCustomQuery class]] 
		|| [[self delegate] isKindOfClass:[SPTableContent class]])) {
		[self editColumn:0 row:[self selectedRow] withEvent:nil select:YES];
		return;
	}

	[super keyDown:theEvent];
}

#pragma mark -

- (void) awakeFromNib
{
	columnDefinitions = nil;
	prefs = [[NSUserDefaults standardUserDefaults] retain];

	if ([NSTableView instancesRespondToSelector:@selector(awakeFromNib)])
		[super awakeFromNib];

}

- (void) dealloc
{
	if (columnDefinitions) [columnDefinitions release];
	[prefs release];

	[super dealloc];
}

@end
