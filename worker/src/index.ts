interface Env {
  DB: D1Database;
}

export default {
  fetch(): Response {
    return Response.json(
      { success: false, error: { code: "not_found" } },
      { status: 404 }
    );
  },
} satisfies ExportedHandler<Env>;
