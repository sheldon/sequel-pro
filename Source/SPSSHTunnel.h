#import <Cocoa/Cocoa.h>

enum spsshtunnel_states
{
	SPSSH_STATE_IDLE = 0,
	SPSSH_STATE_CONNECTING = 1,
	SPSSH_STATE_WAITING_FOR_AUTH = 2,
	SPSSH_STATE_CONNECTED = 3
};

enum spsshtunnel_password_modes
{
	SPSSH_PASSWORD_USES_KEYCHAIN = 0,
	SPSSH_PASSWORD_ASKS_UI = 1
};


@interface SPSSHTunnel : NSObject
{
	NSTask *task;
	NSPipe *standardError;
	id delegate;
	SEL stateChangeSelector;
	NSConnection *passwordConnection;
	NSString *lastError;
	NSString *passwordConnectionName;
	NSString *passwordConnectionVerifyHash;
	NSString *sshHost;
	NSString *sshLogin;
	NSString *remoteHost;
	NSString *password;
	NSString *keychainName;
	NSString *keychainAccount;
	BOOL passwordInKeychain;
	int sshPort;
	int remotePort;
	int localPort;
	int connectionState;
}

- (id) initToHost:(NSString *) theHost port:(int) thePort login:(NSString *) theLogin tunnellingToPort:(int) targetPort onHost:(NSString *) targetHost;
- (BOOL) setConnectionStateChangeSelector:(SEL)theStateChangeSelector delegate:(id)theDelegate;
- (BOOL) setPassword:(NSString *)thePassword;
- (BOOL) setPasswordKeychainName:(NSString *)theName account:(NSString *)theAccount;
- (int) state;
- (NSString *) lastError;
- (int) localPort;
- (void) connect;
- (void) launchTask:(id) dummy;
- (void)disconnect;
- (void) standardErrorHandler:(NSNotification*)aNotification;
- (NSString *) getPasswordWithVerificationHash:(NSString *)theHash;

@end