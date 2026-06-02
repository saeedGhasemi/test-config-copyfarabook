import { lazy, Suspense } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { I18nProvider } from "@/lib/i18n";
import { ThemeProvider } from "@/lib/theme";
import { Navbar } from "@/components/Navbar";
import { UploadProgressPanel } from "@/components/UploadProgressPanel";

const queryClient = new QueryClient();

const Landing = lazy(() => import("./pages/Landing"));
const Auth = lazy(() => import("./pages/Auth"));
const Library = lazy(() => import("./pages/Library"));
const Store = lazy(() => import("./pages/Store"));
const Reader = lazy(() => import("./pages/Reader"));
const Upload = lazy(() => import("./pages/Upload"));
const Edit = lazy(() => import("./pages/Edit"));
const Publish = lazy(() => import("./pages/Publish"));
const Publisher = lazy(() => import("./pages/Publisher"));
const PublisherSettings = lazy(() => import("./pages/PublisherSettings"));
const Admin = lazy(() => import("./pages/Admin"));
const Credits = lazy(() => import("./pages/Credits"));
const EditorRequests = lazy(() => import("./pages/EditorRequests"));
const Profile = lazy(() => import("./pages/Profile"));
const NotFound = lazy(() => import("./pages/NotFound.tsx"));

const App = () => (
  <QueryClientProvider client={queryClient}>
    <I18nProvider>
      <ThemeProvider>
        <TooltipProvider>
          <Toaster />
          <Sonner />
          <BrowserRouter>
            <Navbar />
            <Suspense fallback={<main className="container py-12 text-center text-muted-foreground">در حال بارگذاری…</main>}>
              <Routes>
                <Route path="/" element={<Landing />} />
                <Route path="/auth" element={<Auth />} />
                <Route path="/library" element={<Library />} />
                <Route path="/store" element={<Store />} />
                <Route path="/read/:id" element={<Reader />} />
                <Route path="/upload" element={<Upload />} />
                <Route path="/edit/:id" element={<Edit />} />
                <Route path="/publish/:id" element={<Publish />} />
                <Route path="/publisher/:id" element={<Publisher />} />
                <Route path="/publisher/:id/settings" element={<PublisherSettings />} />
                <Route path="/admin" element={<Admin />} />
                <Route path="/credits" element={<Credits />} />
                <Route path="/editor-requests" element={<EditorRequests />} />
                <Route path="/profile" element={<Profile />} />
                <Route path="*" element={<NotFound />} />
              </Routes>
            </Suspense>
            <UploadProgressPanel />
          </BrowserRouter>
        </TooltipProvider>
      </ThemeProvider>
    </I18nProvider>
  </QueryClientProvider>
);

export default App;
