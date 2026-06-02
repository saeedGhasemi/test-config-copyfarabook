import tehranImg from "@/assets/scene-tehran.jpg";
import princeImg from "@/assets/scene-prince.jpg";
import desertImg from "@/assets/scene-desert.jpg";
import farmImg from "@/assets/scene-farm.jpg";
import heroImg from "@/assets/hero-book.jpg";
import medHeart from "@/assets/med-heart.jpg";
import medBrain from "@/assets/med-brain.jpg";
import medCell from "@/assets/med-cell.jpg";
import medDna from "@/assets/med-dna.jpg";
import medSkeleton from "@/assets/med-skeleton.jpg";
import medLungs from "@/assets/med-lungs.jpg";
import medNeuron from "@/assets/med-neuron.jpg";
import medBlood from "@/assets/med-blood.jpg";
import medCoverAnatomy from "@/assets/med-cover-anatomy.jpg";
import medCoverNeuro from "@/assets/med-cover-neuro.jpg";
import hemoCells from "@/assets/hemo-cells.jpg";
import hemoBloodSmear from "@/assets/hemo-blood-smear.jpg";
import hemoSickleDiagram from "@/assets/hemo-sickle-diagram.jpg";
import hemoCover from "@/assets/hemo-cover.jpg";
import hemoChart from "@/assets/hemo-chart.jpg";
import pathSickleSmear from "@/assets/path-sickle-smear.jpg";
import pathAmlBlasts from "@/assets/path-aml-blasts.jpg";
import pathAllBlasts from "@/assets/path-all-blasts.jpg";
import pathSmearTechnique from "@/assets/path-smear-technique.jpg";
import pathNormalSmear from "@/assets/path-normal-smear.jpg";
import pathMarrowBiopsy from "@/assets/path-marrow-biopsy.jpg";

const mediaMap: Record<string, string> = {
  tehran: tehranImg,
  prince: princeImg,
  desert: desertImg,
  farm: farmImg,
  hero: heroImg,
  "med-heart": medHeart,
  "med-brain": medBrain,
  "med-cell": medCell,
  "med-dna": medDna,
  "med-skeleton": medSkeleton,
  "med-lungs": medLungs,
  "med-neuron": medNeuron,
  "med-blood": medBlood,
  "med-cover-anatomy": medCoverAnatomy,
  "med-cover-neuro": medCoverNeuro,
  "hemo-cells": hemoCells,
  "hemo-blood-smear": hemoBloodSmear,
  "hemo-sickle-diagram": hemoSickleDiagram,
  "hemo-cover": hemoCover,
  "hemo-chart": hemoChart,
  "path-sickle-smear": pathSickleSmear,
  "path-aml-blasts": pathAmlBlasts,
  "path-all-blasts": pathAllBlasts,
  "path-smear-technique": pathSmearTechnique,
  "path-normal-smear": pathNormalSmear,
  "path-marrow-biopsy": pathMarrowBiopsy,
};

const picsumSeedMap: Record<string, string> = {
  "101": "/seed-images/planet1.svg",
  "102": "/seed-images/bio1.svg",
  "103": "/seed-images/quantum1.svg",
  "104": "/seed-images/earth.svg",
  "105": "/seed-images/physics1.svg",
  "201": "/seed-images/nowruz.svg",
  "202": "/seed-images/calligraphy.svg",
  "203": "/seed-images/art1.svg",
  "204": "/seed-images/iran1.svg",
  "301": "/seed-images/wrestle1.svg",
  "302": "/seed-images/tactic.svg",
  "303": "/seed-images/health.svg",
  "401": "/seed-images/conic.svg",
  "402": "/seed-images/calc.svg",
  "403": "/seed-images/bigchart.svg",
  "501": "/seed-images/iran2.svg",
  "502": "/seed-images/cell1.svg",
  "503": "/seed-images/book-boof.svg",
  "504": "/seed-images/cloud1.svg",
  "601": "/seed-images/heart.svg",
  "602": "/seed-images/bio2.svg",
  "603": "/seed-images/herb1.svg",
  "701": "/seed-images/tehran1.svg",
  "702": "/seed-images/cafe.svg",
  "703": "/seed-images/art2.svg",
  "704": "/seed-images/cafe.svg",
  "705": "/seed-images/river.svg",
  "801": "/seed-images/animal.svg",
  "802": "/seed-images/dark.svg",
  "820": "/seed-images/kid1.svg",
  "999": "/seed-images/stats.svg",
};

export const resolveBookMedia = (src: string | null | undefined) => {
  if (!src) return "";
  const mapped = mediaMap[src];
  if (mapped) return mapped;
  const picsumSeed = src.match(/picsum\.photos\/seed\/([^/]+)/)?.[1];
  if (picsumSeed && picsumSeedMap[picsumSeed]) return picsumSeedMap[picsumSeed];
  return src;
};

/**
 * For images stored in Supabase Storage, request an on-the-fly resized
 * variant via the render endpoint. This avoids downloading 1600px covers
 * for tiny card thumbnails. The transformed URL is stable (same query →
 * same response), so the browser cache works across navigations.
 *
 * For local bundled assets (mediaMap entries) or external URLs, returns
 * the resolved URL unchanged.
 */
export const resolveBookCover = (
  src: string | null | undefined,
  opts: { width?: number; height?: number; quality?: number; resize?: "cover" | "contain" | "fill" } = {},
): string => {
  const resolved = resolveBookMedia(src);
  if (!resolved) return "";
  // Only Supabase storage URLs can be transformed
  const m = resolved.match(/^(https?:\/\/[^/]+)\/storage\/v1\/object\/public\/(.+)$/);
  if (!m) return resolved;
  const [, host, rest] = m;
  const params = new URLSearchParams();
  if (opts.width) params.set("width", String(opts.width));
  if (opts.height) params.set("height", String(opts.height));
  params.set("quality", String(opts.quality ?? 70));
  params.set("resize", opts.resize ?? "cover");
  // Strip any existing query
  const path = rest.split("?")[0];
  return `${host}/storage/v1/render/image/public/${path}?${params.toString()}`;
};

