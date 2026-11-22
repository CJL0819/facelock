// SPDX-License-Identifier: MIT
//
// Draws the tweak's icon: a deep blue rounded square with a white Face ID mark
// in it. Writes the Apelin project icon and the three Settings row icons.
// Build and run on the device; not part of the package.
//
//   clang -arch arm64e -mios-version-min=16.0 -fobjc-arc -O1 \
//       -framework Foundation -framework CoreGraphics -framework ImageIO \
//       -o /tmp/makeicon Tools/MakeIcon.m
//   ldid -S /tmp/makeicon && /tmp/makeicon <project root>

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

static void StrokeFaceFrame(CGContextRef context, CGFloat cx, CGFloat cy, CGFloat size, CGFloat lineWidth) {
    CGFloat g = size * 0.255;         // half of the frame
    CGFloat rc = size * 0.092;        // corner radius
    CGFloat arm = size * 0.062;       // straight piece after each corner
    CGFloat left = cx - g;
    CGFloat right = cx + g;
    CGFloat bottom = cy - g;
    CGFloat top = cy + g;

    CGContextSetLineWidth(context, lineWidth);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetStrokeColorWithColor(context, CGColorGetConstantColor(kCGColorWhite));

    struct { CGPoint start; CGPoint corner; CGPoint arcCenter; CGFloat from; CGFloat to; CGFloat clockwise; CGPoint end; CGPoint finish; } brackets[] = {
        // top left
        { CGPointMake(left + rc + arm, top), CGPointMake(left + rc, top),
          CGPointMake(left + rc, top - rc), M_PI_2, M_PI, 0,
          CGPointMake(left, top - rc), CGPointMake(left, top - rc - arm) },
        // top right
        { CGPointMake(right - rc - arm, top), CGPointMake(right - rc, top),
          CGPointMake(right - rc, top - rc), M_PI_2, 0, 1,
          CGPointMake(right, top - rc), CGPointMake(right, top - rc - arm) },
        // bottom left
        { CGPointMake(left, bottom + rc + arm), CGPointMake(left, bottom + rc),
          CGPointMake(left + rc, bottom + rc), M_PI, M_PI_2 * 3.0, 0,
          CGPointMake(left + rc, bottom), CGPointMake(left + rc + arm, bottom) },
        // bottom right
        { CGPointMake(right, bottom + rc + arm), CGPointMake(right, bottom + rc),
          CGPointMake(right - rc, bottom + rc), 0, -M_PI_2, 1,
          CGPointMake(right - rc, bottom), CGPointMake(right - rc - arm, bottom) },
    };

    for (size_t index = 0; index < sizeof(brackets) / sizeof(brackets[0]); index++) {
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, brackets[index].start.x, brackets[index].start.y);
        CGContextAddLineToPoint(context, brackets[index].corner.x, brackets[index].corner.y);
        CGContextAddArc(context,
                        brackets[index].arcCenter.x, brackets[index].arcCenter.y,
                        rc, brackets[index].from, brackets[index].to, brackets[index].clockwise);
        CGContextAddLineToPoint(context, brackets[index].finish.x, brackets[index].finish.y);
        CGContextStrokePath(context);
    }
}

static void DrawFace(CGContextRef context, CGFloat cx, CGFloat cy, CGFloat size) {
    StrokeFaceFrame(context, cx, cy, size, size * 0.076);

    // eyes
    CGFloat eyeRadius = size * 0.031;
    CGContextSetFillColorWithColor(context, CGColorGetConstantColor(kCGColorWhite));
    CGContextFillEllipseInRect(context, CGRectMake(cx - size * 0.078 - eyeRadius, cy + size * 0.042 - eyeRadius, eyeRadius * 2, eyeRadius * 2));
    CGContextFillEllipseInRect(context, CGRectMake(cx + size * 0.078 - eyeRadius, cy + size * 0.042 - eyeRadius, eyeRadius * 2, eyeRadius * 2));

    // a smile below them
    CGContextSetLineWidth(context, size * 0.045);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(context, CGColorGetConstantColor(kCGColorWhite));
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, cx - size * 0.082, cy - size * 0.04);
    CGContextAddQuadCurveToPoint(context, cx, cy - size * 0.15, cx + size * 0.082, cy - size * 0.04);
    CGContextStrokePath(context);
}

static void DrawIcon(CGContextRef context, CGFloat side, CGFloat inset) {
    CGFloat s = side;
    // Clip to the icon square so the gradient keeps a rounded corner.
    CGFloat margin = s * inset;
    CGRect square = CGRectInset(CGRectMake(0, 0, s, s), margin, margin);
    CGFloat radius = square.size.width * 0.225;
    CGPathRef rounded = CGPathCreateWithRoundedRect(square, radius, radius, NULL);
    CGContextSaveGState(context);
    CGContextAddPath(context, rounded);
    CGContextClip(context);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[] = {
        0.07, 0.10, 0.26, 1.0,
        0.09, 0.20, 0.55, 1.0,
        0.22, 0.45, 1.00, 1.0,
    };
    CGFloat locations[] = {0.0, 0.55, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
    CGContextDrawLinearGradient(context, gradient,
                                CGPointMake(CGRectGetMinX(square), CGRectGetMaxY(square)),
                                CGPointMake(CGRectGetMaxX(square), CGRectGetMinY(square)),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(context);
    CGPathRelease(rounded);

    DrawFace(context, s / 2.0, s / 2.0, s);
}

static BOOL WritePNG(CGContextRef context, NSString *path) {
    CGImageRef image = CGBitmapContextCreateImage(context);
    if (image == NULL) {
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (destination != NULL) {
        CGImageDestinationAddImage(destination, image, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return ok;
}

static BOOL WriteIcon(NSString *path, size_t side, CGFloat inset) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) {
        return NO;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetShouldAntialias(context, true);
    CGContextClearRect(context, CGRectMake(0, 0, side, side));
    DrawIcon(context, (CGFloat)side, inset);
    BOOL ok = WritePNG(context, path);
    CGContextRelease(context);
    return ok;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: makeicon <project root>\n");
            return 2;
        }
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSArray *jobs = @[
            @[@"apelin-icon.png", @1024, @0.0],
            @[@"Resources/icon@3x.png", @87, @0.06],
            @[@"Resources/icon@2x.png", @58, @0.06],
            @[@"Resources/icon.png", @29, @0.06],
        ];
        for (NSArray *job in jobs) {
            NSString *path = [root stringByAppendingPathComponent:job[0]];
            if (!WriteIcon(path, [job[1] unsignedIntegerValue], [job[2] doubleValue])) {
                fprintf(stderr, "failed: %s\n", [job[0] UTF8String]);
                return 1;
            }
            printf("wrote %s\n", [job[0] UTF8String]);
        }
    }
    return 0;
}
