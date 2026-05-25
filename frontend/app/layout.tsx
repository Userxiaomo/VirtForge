import type { Metadata } from "next";
import { AppProviders } from "../components/app-providers";
import "./globals.css";

export const metadata: Metadata = {
  title: "VPS Control Panel",
  description: "Master control panel for managed KVM VPS nodes.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>
        <AppProviders>{children}</AppProviders>
      </body>
    </html>
  );
}
