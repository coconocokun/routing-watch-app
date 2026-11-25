import { useEffect, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";

type Phase = "Waiting for iPhone" | "Confirm start" | "Recording" | "Paused" | "Waiting to sync" | "Transferred";

export default function App() {
  const [phase, setPhase] = useState<Phase>("Waiting for iPhone");
  const [seconds, setSeconds] = useState(0);
  useEffect(() => {
    if (phase !== "Recording") return;
    const timer = setInterval(() => setSeconds((value) => value + 1), 1000);
    return () => clearInterval(timer);
  }, [phase]);

  const active = phase === "Recording" || phase === "Paused";
  const bpm = seconds >= 4 ? 86 + Math.floor(seconds / 4) % 12 : null;
  const actions: Record<Phase, [string, Phase]> = {
    "Waiting for iPhone": ["Simulate phone start", "Confirm start"],
    "Confirm start": ["Start walk", "Recording"],
    Recording: ["Pause", "Paused"],
    Paused: ["Resume", "Recording"],
    "Waiting to sync": ["Simulate phone receipt", "Transferred"],
    Transferred: ["Reset preview", "Waiting for iPhone"]
  };
  const [label, next] = actions[phase];
  return <SafeAreaProvider><SafeAreaView style={styles.screen}>
    <Text style={styles.caption}>WATCH PREVIEW · SIMULATED DATA</Text>
    <View style={styles.face}>
      <Text style={styles.title}>{phase}</Text>
      {active && <>
        <Text style={styles.bpm}>{bpm ?? "—"} <Text style={styles.meta}>bpm</Text></Text>
        <Text style={styles.meta}>{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, "0")} · {Math.floor(seconds / 4)} samples</Text>
      </>}
      <Pressable accessibilityRole="button" style={styles.button} onPress={() => {
        if (phase === "Transferred") setSeconds(0);
        setPhase(next);
      }}><Text style={styles.buttonText}>{label}</Text></Pressable>
      {active && <Pressable accessibilityRole="button" onPress={() => setPhase("Waiting to sync")}><Text style={styles.finish}>Finish walk</Text></Pressable>}
    </View>
  </SafeAreaView></SafeAreaProvider>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, alignItems: "center", justifyContent: "center", padding: 24, backgroundColor: "#161c21", gap: 20 },
  face: { width: "100%", maxWidth: 268, minHeight: 248, backgroundColor: "#080b0d", borderColor: "#3b484d", borderWidth: 2, borderRadius: 44, alignItems: "center", justifyContent: "center", padding: 21, gap: 9 },
  caption: { color: "#9fb5ae", fontSize: 12, fontWeight: "700", letterSpacing: 2 },
  title: { color: "#ecf7f1", fontSize: 21, fontWeight: "700", textAlign: "center" },
  bpm: { color: "#f9a296", fontSize: 48, fontWeight: "700", fontVariant: ["tabular-nums"] },
  meta: { color: "#c3d3cd", fontSize: 14, fontVariant: ["tabular-nums"] },
  button: { width: "100%", backgroundColor: "#b8edd2", borderRadius: 20, padding: 11, marginTop: 6, alignItems: "center" },
  buttonText: { color: "#0c2d22", fontWeight: "700" },
  finish: { color: "#f9a296", padding: 5, fontWeight: "600" },
});
