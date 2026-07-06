// podcast-token-helper — prints an Apple Podcasts FairPlay-signed bearer JWT to
// stdout, or exits non-zero with a reason on stderr.
//
// This is the ONLY unsafe code in the podcast-transcript feature. It dlopens the
// private `PodcastsFoundation` framework and uses `AMSMescal` /
// `AMSMescalSession` / `IMURLBag` to produce the `X-Apple-ActionSignature` header
// that the token service requires. Adapted (token-fetch only) from
// dado3212/apple-podcast-transcript-downloader `FetchTranscript.m`, vendored at
// docs/vendor/apple-podcast-transcript-downloader/. See
// plans/podcast-transcripts.md.
//
// Isolated in its own executable ON PURPOSE: the private signing call can segfault
// during promise cleanup, and the reference forks a child to survive it. Running
// this as a separate process the app spawns means a crash costs one failed fetch,
// never the app. We keep the fork/pipe belt-and-suspenders from the reference.
//
// Build note (mirrored in Package.swift): links Foundation and, via
// -F/System/Library/PrivateFrameworks, AppleMediaServices; the Podcasts framework
// itself is dlopen'd at runtime so there's no link-time dependency.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Fetch a fresh bearer token in a forked child (the private call can segfault on
// cleanup); the parent reads the token off a pipe. Returns the trimmed token, or
// nil on failure.
static NSString *FetchBearerToken(void) {
  int pipefd[2];
  if (pipe(pipefd) != 0) {
    return nil;
  }

  pid_t pid = fork();
  if (pid == 0) {
    // Child: redirect stdout to the pipe, do the signing, print the token.
    close(pipefd[0]);
    dup2(pipefd[1], STDOUT_FILENO);
    close(pipefd[1]);

    @autoreleasepool {
      dlopen("/System/Library/PrivateFrameworks/PodcastsFoundation.framework/PodcastsFoundation", RTLD_LAZY);
      Class AMSMescal = objc_getClass("AMSMescal");
      Class AMSMescalSession = objc_getClass("AMSMescalSession");
      Class AMSURLRequestClass = objc_getClass("AMSURLRequest");
      Class IMURLBag = objc_getClass("IMURLBag");

      if (!AMSMescal || !AMSMescalSession || !AMSURLRequestClass || !IMURLBag) {
        fprintf(stderr, "PodcastsFoundation classes unavailable (unsupported macOS version?).\n");
        exit(1);
      }

      NSString *storeFront = @"143441-1,42 t:podcasts1";
      NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
      [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
      [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
      NSString *timestamp = [formatter stringFromDate:[NSDate date]];

      NSURL *tokenURL = [NSURL URLWithString:@"https://sf-api-token-service.itunes.apple.com/apiToken?clientClass=apple&clientId=com.apple.podcasts.macos&os=OS%20X&osVersion=15.5&productVersion=1.1.0&version=2"];
      NSMutableURLRequest *nsRequest = [NSMutableURLRequest requestWithURL:tokenURL];

      id urlRequest = [[AMSURLRequestClass alloc] initWithRequest:nsRequest];
      [urlRequest setValue:timestamp forHTTPHeaderField:@"x-request-timestamp"];
      [urlRequest setValue:storeFront forHTTPHeaderField:@"X-Apple-Store-Front"];

      id signature = [AMSMescal _signedActionDataFromRequest:urlRequest policy:@{
        @"fields": @[@"clientId"],
        @"headers": @[@"x-apple-store-front", @"x-apple-client-application", @"x-request-timestamp"]
      }];

      id session = [AMSMescalSession defaultSession];
      id urlBag = [[IMURLBag alloc] init];

      if (![session respondsToSelector:@selector(signData:bag:)]) {
        fprintf(stderr, "AMSMescalSession lacks signData:bag: (unsupported macOS version).\n");
        exit(1);
      }

      dispatch_semaphore_t sema = dispatch_semaphore_create(0);
      id signedPromise = [session signData:signature bag:urlBag];
      [signedPromise thenWithBlock:^(id result) {
        NSString *actionSignature = [(NSData *)result base64EncodedStringWithOptions:0];

        NSMutableURLRequest *signedRequest = [NSMutableURLRequest requestWithURL:tokenURL];
        [signedRequest setValue:timestamp forHTTPHeaderField:@"x-request-timestamp"];
        [signedRequest setValue:storeFront forHTTPHeaderField:@"X-Apple-Store-Front"];
        [signedRequest setValue:actionSignature forHTTPHeaderField:@"X-Apple-ActionSignature"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:signedRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          NSString *token = json[@"token"];
          if (token) {
            printf("%s\n", [token UTF8String]);
          } else {
            fprintf(stderr, "Token service returned no token.\n");
          }
          dispatch_semaphore_signal(sema);
        }];
        [task resume];

        // Double semaphore mirrors the reference: papers over a segfault during
        // thenWithBlock cleanup by keeping the child alive until the token is read.
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
      }];
      dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    }
    exit(0);
  }

  // Parent: read the token from the pipe.
  close(pipefd[1]);
  char buffer[8192] = {0};
  ssize_t n = read(pipefd[0], buffer, sizeof(buffer) - 1);
  close(pipefd[0]);

  int status = 0;
  waitpid(pid, &status, 0);
  if (n > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    return [[NSString stringWithUTF8String:buffer]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  }
  return nil;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *token = FetchBearerToken();
    // A valid JWT starts with "ey" (base64 of `{"`).
    if (!token || token.length < 10 || ![token hasPrefix:@"ey"]) {
      fprintf(stderr, "Failed to obtain a valid bearer token.\n");
      return 1;
    }
    printf("%s\n", [token UTF8String]);
    return 0;
  }
}
